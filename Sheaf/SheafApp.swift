import SwiftData
import SwiftUI

@main
struct SheafApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var library: LibraryStore
    @State private var workspace: Workspace

    init() {
        let container: ModelContainer
        do {
            container = try LibraryStore.makeContainer()
        } catch {
            // Keep the app usable even if the library file can't be opened;
            // the library just won't be saved this session.
            NSLog("Sheaf: couldn't open the library (\(error)); using a temporary one.")
            container = try! LibraryStore.makeContainer(inMemory: true)
        }
        self.container = container
        let library = LibraryStore(context: container.mainContext)
        let workspace = Workspace(library: library)
        workspace.restore()
        _library = State(initialValue: library)
        _workspace = State(initialValue: workspace)
        WindowRouter.shared.library = library
        WindowRouter.shared.workspace = workspace
    }

    var body: some Scene {
        // One window: the library, or the PDF you're reading.
        Window("Sheaf", id: "main") {
            MainWindow()
                .environment(library)
                .environment(workspace)
                .modelContainer(container)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { SheafCommands(workspace: workspace) }
    }
}
