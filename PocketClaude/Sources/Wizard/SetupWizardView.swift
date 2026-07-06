import SwiftUI
import UniformTypeIdentifiers

/// First-run wizard, three steps per spec section 5:
/// 1. Workspace folder (security-scoped bookmark)
/// 2. Performance check (JIT probe)
/// 3. Sign in — placeholder until the VM engine lands (M0/M3); the real
///    flow boots headless, watches the control channel for AUTH_URL and
///    hands off to SFSafariViewController.
struct SetupWizardView: View {
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var step = 0
    @State private var showFolderPicker = false
    @State private var workspaceName: String? = WorkspaceStore.displayName
    @State private var workspaceError: String?
    // JIT probe removed in v0.2: the RWX mmap check on iOS returns true
    // due to hardened runtime allowing the allocation while blocking
    // actual execution, so "available" was misleading. The app runs in
    // interpreter mode unconditionally on unmodified iOS.

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                switch step {
                case 0: workspaceStep
                case 1: performanceStep
                default: signInStep
                }
                Spacer()
                footer
            }
            .padding()
            .navigationTitle("Pocket Claude")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try WorkspaceStore.save(url: url)
                    workspaceName = WorkspaceStore.displayName
                    workspaceError = nil
                } catch {
                    workspaceError = error.localizedDescription
                }
            case .failure(let error):
                workspaceError = error.localizedDescription
            }
        }
    }

    private var workspaceStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Choose a workspace")
                .font(.title2.bold())
            Text("Pick or create a folder in iCloud Drive or On My iPhone. The VM mounts it at /workspace, and Claude Code runs inside it. Changes show up in the Files app live.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showFolderPicker = true
            } label: {
                Label(
                    workspaceName.map { "Workspace: \($0)" } ?? "Choose Folder",
                    systemImage: workspaceName == nil ? "folder" : "checkmark.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if let workspaceError {
                Text(workspaceError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var performanceStep: some View {
        let jit = pocket_probe_jit()
        return VStack(spacing: 16) {
            Image(systemName: jit == 1 ? "hare.fill" : "tortoise.fill")
                .font(.system(size: 56))
                .foregroundStyle(jit == 1 ? .green : .orange)
            Text(jit == 1 ? "JIT allowed" : "Interpreter mode")
                .font(.title2.bold())
            if jit == 1 {
                Text("MAP_JIT allocation succeeded — this app has the JIT entitlement. QEMU can emit native ARM64 code for the guest, so boot and Claude Code should run at near-native speed.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("If the launcher (StikDebug etc.) also grants the runtime exec permission, boot to Alpine login should be ~15-30 seconds.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("MAP_JIT allocation failed. QEMU falls back to its TCTI interpreter — functional but noticeably slower.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("To enable JIT: launch through StikDebug (iOS 17.4+) or SideJITServer. These grant the runtime exec permission the JIT entitlement alone doesn't cover.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signInStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Sign in to Claude")
                .font(.title2.bold())
            Text("Sign-in happens on the first boot. The VM launches claude automatically; when it prints a login URL, Pocket Claude notices and offers to open it in Safari, then hands the code back to the terminal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("If the sheet doesn't appear, scroll the terminal for the URL and paste-back manually.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < 2 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 0 && workspaceName == nil)
            } else {
                Button("Finish") {
                    logBoot("wizard_finish_tapped")
                    setupComplete = true
                    logBoot("wizard_finish_done")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
