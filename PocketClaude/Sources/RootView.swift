import SwiftUI

struct RootView: View {
    @AppStorage("setupComplete") private var setupComplete = false
    @State private var showBootLog = false

    var body: some View {
        VStack(spacing: 0) {
            DiagnosticBanner(showBootLog: $showBootLog)
            if setupComplete {
                MainView()
            } else {
                SetupWizardView()
            }
        }
        .sheet(isPresented: $showBootLog) { BootLogView() }
    }
}

/// v0.2.3 diagnostic banner. Tap to view the boot log inline — saves the
/// user having to open Files.
private struct DiagnosticBanner: View {
    @Binding var showBootLog: Bool
    var body: some View {
        Button {
            showBootLog = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope")
                Text("v0.2.3 diagnostic. Tap for boot log.")
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.85))
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }
}

private struct BootLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = "(reading...)"

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("pocket-claude-boot.log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy") {
                        UIPasteboard.general.string = content
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        guard let docs = try? FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
              ) else {
            content = "(no Documents directory)"
            return
        }
        let path = docs.appendingPathComponent("pocket-claude-boot.log").path
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            content = "(log file not present yet)"
            return
        }
        content = data.isEmpty ? "(log file empty)" : data
    }
}
