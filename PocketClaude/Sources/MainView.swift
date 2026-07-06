import SwiftUI
import SafariServices

struct MainView: View {
    @EnvironmentObject var env: PocketClaudeEnvironment
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var showAuthSheet = false
    @State private var authSheetURL: URL?
    @State private var codeToPaste: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                terminal
                KeyRowView { bytes in
                    env.engine?.send(bytes: bytes)
                }
            }
            .background(.black)
            .navigationTitle(WorkspaceStore.displayName ?? "Pocket Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear {
                if env.engine == nil {
                    env.startEngine()
                }
            }
            .onChange(of: env.pendingAuthURL) { _, url in
                if let url {
                    authSheetURL = url
                    showAuthSheet = true
                }
            }
            .sheet(isPresented: $showAuthSheet) { authSheet }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        if let engine = env.engine {
            TerminalHostView(engine: engine)
        } else {
            Color.black
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                Text(env.vmState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    env.startEngine()
                } label: {
                    Label("Restart VM", systemImage: "arrow.clockwise")
                }
                Button {
                    openWorkspaceInFiles()
                } label: {
                    Label("Open Workspace in Files", systemImage: "folder")
                }
                if let url = env.pendingAuthURL {
                    Button {
                        authSheetURL = url
                        showAuthSheet = true
                    } label: {
                        Label("Open Claude Sign-in", systemImage: "person.badge.key")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    setupComplete = false
                } label: {
                    Label("Re-run Setup", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var authSheet: some View {
        if let url = authSheetURL {
            VStack(spacing: 0) {
                SafariView(url: url)
                    .frame(maxHeight: .infinity)
                VStack(spacing: 8) {
                    Text("Paste the code shown in the browser, then send it back to the VM:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Auth code", text: $codeToPaste)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        Button("Send") {
                            let trimmed = codeToPaste.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            var bytes = Array(trimmed.utf8)
                            bytes.append(0x0d) // CR
                            env.engine?.send(bytes: bytes)
                            codeToPaste = ""
                            showAuthSheet = false
                            env.pendingAuthURL = nil
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(.thinMaterial)
            }
        }
    }

    private var stateColor: Color {
        switch env.vmState {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .error: return .red
        }
    }

    private func openWorkspaceInFiles() {
        guard let url = WorkspaceStore.resolve() else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        if let filesURL = components?.url {
            UIApplication.shared.open(filesURL)
        }
    }
}

/// SFSafariViewController wrapped for SwiftUI (M3 sign-in handoff).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
