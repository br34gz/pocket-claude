import SwiftUI

@main
struct PocketClaudeApp: App {
    @StateObject private var env = PocketClaudeEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // M4 lifecycle: pause the VM when backgrounded (spec §5).
                (env.engine as? QEMUVMEngine)?.pause()
            case .active:
                (env.engine as? QEMUVMEngine)?.resume()
            default: break
            }
        }
    }
}
