#!/usr/bin/env python3
"""
Full system-mode QEMU boot smoke test for the guest qcow2.

Runs on ubuntu-latest CI. Boots the packed image with the SAME layout
the iOS app uses (direct kernel, virtio-net-device MMIO, virtio-serial
control channel, unix-socket console+control chardevs, virtio-9p
workspace passthrough) and watches the console for either:

  PASS - `claude --version: X.Y.Z` printed AND interactive claude
         survives INTERACTIVE_WATCH_S seconds without a fail marker.
  FAIL - one of FAIL_MARKERS seen on the console during the run.

v0.7.4: added virtio-9p workspace mount. Previous smokes booted with
no /workspace, so claude ran in a fresh $HOME and didn't touch the
9p mount that on-device triggers `null bytes` fs errors. The smoke
now mirrors on-device conditions, including a pre-created skeleton
of directories the guest's /pocket-init would set up.

usage:
    smoke-test-qcow2.py <qcow2> <vmlinuz> <initramfs> [<workspace_dir>]
"""
from __future__ import annotations

import os
import re
import socket
import subprocess
import sys
import time

TIMEOUT_S = 900
INTERACTIVE_WATCH_S = 60
CONSOLE_SOCK = "/tmp/smoke-console.sock"
CONTROL_SOCK = "/tmp/smoke-control.sock"
DEFAULT_WORKSPACE = "/tmp/pocket-ws"

SUCCESS_RE = re.compile(rb"claude --version:\s*([0-9]+\.[0-9]+\.[0-9]+)")

FAIL_MARKERS = [
    b"Module not found",
    b"null bytes",
    b"TypeError",
    b"Kernel panic",
    b"Segmentation fault",
    b"claude --version FAILED",
    b"claude exited unexpectedly",
    # Bun / JavaScriptCore DFG JIT tier assertion (v0.7.0 mode).
    b"DFG ASSERTION",
    b"isFlushed()",
    # Bun / JavaScriptCore concurrent-GC race (v0.7.2 mode).
    b"marks not empty",
    b"Block lock is held",
    b"Marking version of block",
    b"Marking version of heap",
    b"ASSERTION FAILED",
    # Generic Node process crash surface.
    b"Claude Code could not start",
]


def prep_workspace(root: str) -> str:
    """Create the workspace dir the guest will mount over virtio-9p.

    Pre-creates the .claude skeleton so claude-code doesn't hit its
    directory-touch code path first thing (theory: that path is where
    the `null bytes` fs error fires under TCTI emulation - if the
    dirs exist, claude walks them instead of trying to create them).
    """
    os.makedirs(root, exist_ok=True)
    for sub in ("workflows", "sessions", "logs", "cache"):
        os.makedirs(os.path.join(root, ".claude", sub), exist_ok=True)
    # 9p mount needs the outer dir world-readable for the security_model
    # to translate uid/gid properly. Fine on a throwaway CI mount.
    os.chmod(root, 0o777)
    return root


def start_qemu(qcow2: str, kernel: str, initrd: str, workspace: str) -> subprocess.Popen:
    for p in (CONSOLE_SOCK, CONTROL_SOCK):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass
    args = [
        "qemu-system-aarch64",
        "-M", "virt",
        "-cpu", "cortex-a72",
        "-smp", "2",
        "-m", "1024",
        "-display", "none",
        "-nodefaults",
        "-no-user-config",
        "-kernel", kernel,
        "-initrd", initrd,
        "-append", "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rw quiet init=/pocket-init",
        "-drive", f"file={qcow2},if=virtio,format=qcow2",
        "-netdev", "user,id=net0",
        "-device", "virtio-net-device,netdev=net0",
        "-chardev", f"socket,id=console0,path={CONSOLE_SOCK},server=on,wait=off",
        "-serial", "chardev:console0",
        "-device", "virtio-serial-device,id=vser0",
        "-chardev", f"socket,id=ctrl0,path={CONTROL_SOCK},server=on,wait=off",
        "-device", "virtserialport,chardev=ctrl0,name=pocket.control",
        # v0.7.4: virtio-9p workspace passthrough matching the app's
        # QEMUVMEngine args. Guest mounts this at /workspace via
        # /pocket-init (or /etc/fstab if systemd were doing it).
        "-fsdev", f"local,security_model=mapped,id=fsdev0,path={workspace}",
        "-device", f"virtio-9p-pci,fsdev=fsdev0,mount_tag=workspace",
    ]
    print("== launching qemu ==")
    print(" ".join(args))
    return subprocess.Popen(args)


def connect_sock(path: str, retries: int = 60, delay: float = 0.5):
    for _ in range(retries):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            s.setblocking(False)
            return s
        except OSError:
            time.sleep(delay)
    return None


def main() -> int:
    if len(sys.argv) < 4:
        print(f"usage: {sys.argv[0]} <qcow2> <vmlinuz> <initramfs> [<workspace_dir>]",
              file=sys.stderr)
        return 2
    qcow2, kernel, initrd = sys.argv[1:4]
    workspace = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_WORKSPACE
    workspace = prep_workspace(workspace)
    print(f"[smoke] workspace at {workspace} pre-populated with .claude/ skeleton")

    qemu = start_qemu(qcow2, kernel, initrd, workspace)
    try:
        console = connect_sock(CONSOLE_SOCK)
        control = connect_sock(CONTROL_SOCK)
        if not console or not control:
            print("SMOKE FAIL: could not connect chardev sockets")
            return 1

        console_buffer = b""
        control_buffer = b""
        deadline = time.time() + TIMEOUT_S
        boot_ok = False
        claude_variant = None
        guest_os = None
        detected_version = None
        version_seen_at = None

        while time.time() < deadline:
            for name, sock in (("console", console), ("control", control)):
                try:
                    data = sock.recv(4096)
                except BlockingIOError:
                    continue
                except OSError as exc:
                    print(f"SMOKE FAIL: {name} sock err {exc}")
                    return 1
                if not data:
                    continue
                if name == "console":
                    console_buffer += data
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                else:
                    control_buffer += data
                    while b"\n" in control_buffer:
                        line, control_buffer = control_buffer.split(b"\n", 1)
                        line = line.strip()
                        text = line.decode("utf-8", "replace")
                        print(f"[control] {text}")
                        if text == "BOOT_OK":
                            boot_ok = True
                        elif text.startswith("CLAUDE_VARIANT "):
                            claude_variant = text[len("CLAUDE_VARIANT "):]
                        elif text.startswith("GUEST_OS "):
                            guest_os = text[len("GUEST_OS "):]

            for marker in FAIL_MARKERS:
                if marker in console_buffer:
                    print(f"\nSMOKE FAIL: caught fail marker: {marker.decode()}")
                    print(f"  boot_ok={boot_ok}, claude_variant={claude_variant}, "
                          f"guest_os={guest_os}, detected_version={detected_version}")
                    return 1

            if version_seen_at is None:
                m = SUCCESS_RE.search(console_buffer)
                if m:
                    detected_version = m.group(1).decode()
                    version_seen_at = time.time()
                    print(
                        f"\n[smoke] --version -> {detected_version}. "
                        f"Watching interactive claude for {INTERACTIVE_WATCH_S}s..."
                    )
            elif time.time() - version_seen_at > INTERACTIVE_WATCH_S:
                print(
                    f"\nSMOKE PASS: claude --version -> {detected_version} "
                    f"and interactive claude survived {INTERACTIVE_WATCH_S}s "
                    f"without a crash marker "
                    f"(claude_variant={claude_variant}, guest_os={guest_os}, "
                    f"boot_ok={boot_ok})"
                )
                return 0

            time.sleep(0.1)

        print(f"\nSMOKE FAIL: timed out after {TIMEOUT_S}s")
        print(f"boot_ok={boot_ok}, claude_variant={claude_variant}")
        return 1
    finally:
        try:
            qemu.terminate()
            qemu.wait(timeout=10)
        except Exception:
            qemu.kill()


if __name__ == "__main__":
    sys.exit(main())
