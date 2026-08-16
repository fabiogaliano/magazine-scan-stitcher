import SwiftUI

@main
struct MagazineScanApp: App {
    @StateObject private var workspace = WorkspaceModel()
    @StateObject private var scanners = ScannerService()

    var body: some Scene {
        WindowGroup {
            RootView(workspace: workspace, scanners: scanners)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Scan…") { workspace.importFiles() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export…") { workspace.exportCurrent() }
                    .keyboardShortcut("s")
                    .disabled(workspace.selectedPage == nil)
            }
        }
    }
}
