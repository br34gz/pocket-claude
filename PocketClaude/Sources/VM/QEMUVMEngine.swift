import Foundation

/// Real VM engine: dlopens qemu-aarch64-softmmu.framework from the app
/// bundle (extracted at CI time from UTM-SE.ipa — TCTI-interpreter build,
/// matches Pocket Claude's accepted slow-mode fallback per spec sections 2
/// and 6) and runs it on a background thread. Speaks to the guest over
/// unix-socket chardevs: console (serial console -> SwiftTerm), control
/// (spec section 4.6 events), QMP (lifecycle pause/resume).
///
/// Only one instance can run per process — qemu holds process-global state.
final class QEMUVMEngine: VMEngine {
    private(set) var state: VMState = .stopped {
        didSet {
            let s = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
        }
    }
    var onOutput: (([UInt8]) -> Void)?
    var onStateChange: ((VMState) -> Void)?

    /// Callbacks for events parsed off the control channel.
    var onAuthURL: ((URL) -> Void)?
    var onBootOK: (() -> Void)?

    private let workspacePath: String?
    private let ramMB: Int
    private let vcpus: Int

    private let consoleSock = UnixSocket(label: "console")
    private let controlSock = UnixSocket(label: "control")
    private let qmpSock = UnixSocket(label: "qmp")

    private var runtimeDir: URL?
    private var controlBuffer = ""

    private static var isRunning = false

    init(workspacePath: String?, ramMB: Int = 1024, vcpus: Int = 2) {
        self.workspacePath = workspacePath
        self.ramMB = ramMB
        self.vcpus = vcpus
    }

    func start() {
        guard !Self.isRunning else {
            state = .error("VM already running in this process")
            return
        }
        guard let qemuPath = GuestAssets.qemuFrameworkPath() else {
            state = .error("qemu-aarch64-softmmu.framework missing from app bundle")
            return
        }
        Self.isRunning = true
        state = .starting

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let assets = try GuestAssets.materialize()
                let dir = try self.prepareRuntimeDir()
                self.runtimeDir = dir

                let consolePath = dir.appendingPathComponent("console.sock").path
                let controlPath = dir.appendingPathComponent("control.sock").path
                let qmpPath = dir.appendingPathComponent("qmp.sock").path

                // Args built into a plain [String] then bridged to
                // char**. Note: no -daemonize, no -nographic; we're
                // in-process. -display none suppresses SDL/Cocoa init.
                var args: [String] = [
                    "qemu-aarch64-softmmu",
                    "-M", "virt,highmem=off",
                    "-cpu", "cortex-a72",
                    "-smp", "\(self.vcpus)",
                    "-m", "\(self.ramMB)",
                    "-display", "none",
                    "-nodefaults",
                    "-no-user-config",
                    "-rtc", "base=utc,clock=host",
                    "-kernel", assets.kernel.path,
                    "-initrd", assets.initramfs.path,
                    "-append", "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rw quiet",
                    "-drive", "file=\(assets.disk.path),if=virtio,format=qcow2,cache=writeback,discard=unmap",
                    "-nic", "user,model=virtio-net-pci",
                    // Serial console
                    "-chardev", "socket,id=console0,path=\(consolePath),server=on,wait=off",
                    "-serial", "chardev:console0",
                    // Control channel via virtio-serial (spec section 4.6)
                    "-device", "virtio-serial-pci,id=vser0",
                    "-chardev", "socket,id=ctrl0,path=\(controlPath),server=on,wait=off",
                    "-device", "virtserialport,chardev=ctrl0,name=pocket.control",
                    // QMP monitor for lifecycle (spec section 5)
                    "-qmp", "unix:\(qmpPath),server=on,wait=off",
                ]

                if let ws = self.workspacePath {
                    args.append(contentsOf: [
                        "-fsdev", "local,security_model=mapped,id=fsdev0,path=\(ws)",
                        "-device", "virtio-9p-pci,fsdev=fsdev0,mount_tag=workspace",
                    ])
                }

                // Connect side channels shortly after boot starts. We do
                // this from a helper queue so it can race qemu_init.
                DispatchQueue.global(qos: .userInitiated).async {
                    self.connectSockets(consolePath: consolePath,
                                        controlPath: controlPath,
                                        qmpPath: qmpPath)
                }

                self.runQemu(dylib: qemuPath, args: args)
                self.state = .stopped
                Self.isRunning = false
            } catch {
                self.state = .error(error.localizedDescription)
                Self.isRunning = false
            }
        }
    }

    private func runQemu(dylib: String, args: [String]) {
        // Convert [String] to a mutable array of const-char pointers.
        // We strdup each entry so the storage outlives the call and can
        // be safely handed to qemu_init (which keeps argv references).
        var cArgs: [UnsafePointer<CChar>?] = args.map { s in
            UnsafePointer(strdup(s))
        }
        defer {
            for p in cArgs {
                if let p { free(UnsafeMutablePointer(mutating: p)) }
            }
        }
        let argc = Int32(args.count)
        cArgs.withUnsafeMutableBufferPointer { buf in
            _ = pocket_qemu_run(dylib, argc, buf.baseAddress)
        }
    }

    private func connectSockets(consolePath: String, controlPath: String, qmpPath: String) {
        // Console: bytes both ways
        consoleSock.onData = { [weak self] bytes in self?.onOutput?(bytes) }
        if consoleSock.connect(path: consolePath) {
            consoleSock.startReading()
        }
        // Control channel: parse line-oriented events
        controlSock.onData = { [weak self] bytes in self?.handleControlBytes(bytes) }
        if controlSock.connect(path: controlPath) {
            controlSock.startReading()
        }
        // QMP: read the greeting, send capabilities negotiation
        qmpSock.onData = { _ in /* silently absorb replies */ }
        if qmpSock.connect(path: qmpPath) {
            qmpSock.startReading()
            let neg = "{\"execute\":\"qmp_capabilities\"}\n"
            qmpSock.write(Array(neg.utf8))
            // Mark running only once QMP is up — a decent proxy for
            // "qemu is far enough along to accept input on the serial
            // console." A separate BOOT_OK from the guest tightens this.
            state = .running(jit: false)
        }
    }

    private func handleControlBytes(_ bytes: [UInt8]) {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return }
        controlBuffer += s
        while let nlIdx = controlBuffer.firstIndex(of: "\n") {
            let line = String(controlBuffer[..<nlIdx])
                .trimmingCharacters(in: .whitespaces)
            controlBuffer.removeSubrange(...nlIdx)
            handleControlLine(line)
        }
    }

    private func handleControlLine(_ line: String) {
        if line == "BOOT_OK" {
            DispatchQueue.main.async { [weak self] in self?.onBootOK?() }
            return
        }
        if line.hasPrefix("AUTH_URL ") {
            let raw = String(line.dropFirst("AUTH_URL ".count))
            if let url = URL(string: raw) {
                DispatchQueue.main.async { [weak self] in self?.onAuthURL?(url) }
            }
        }
    }

    func send(bytes: [UInt8]) {
        consoleSock.write(bytes)
    }

    func sendToControl(_ text: String) {
        controlSock.write(Array(text.utf8))
    }

    func stop() {
        // Ask qemu to quit; qemu_main_loop will return and the runQemu
        // thread will exit.
        sendQMP("{\"execute\":\"quit\"}")
    }

    func pause() {
        sendQMP("{\"execute\":\"stop\"}")
    }

    func resume() {
        sendQMP("{\"execute\":\"cont\"}")
    }

    private func sendQMP(_ json: String) {
        qmpSock.write(Array((json + "\n").utf8))
    }

    private func prepareRuntimeDir() throws -> URL {
        // Use a per-launch dir under Caches; unix socket paths are
        // capped at 104 chars on Darwin, so keep this short.
        let base = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("qemu-rt")
        // Fresh directory each launch — clears stale sockets from a
        // previous crash so the new qemu can bind them.
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
