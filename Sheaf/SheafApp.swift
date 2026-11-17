import SwiftData
import SwiftUI

@main
struct SheafApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var library: LibraryStore
    @State private var workspace: Workspace

    /// True while the unit tests run inside the app. Then Sheaf uses a
    /// throwaway library, reopens no PDFs and shows no window, so tests never
    /// touch the real library, the user's files or the screen.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        let container: ModelContainer
        do {
            container = try LibraryStore.makeContainer(inMemory: Self.isRunningTests)
        } catch {
            // Keep the app usable even if the library file can't be opened;
            // the library just won't be saved this session.
            NSLog("Sheaf: couldn't open the library (\(error)); using a temporary one.")
            container = try! LibraryStore.makeContainer(inMemory: true)
        }
        self.container = container
        let library = LibraryStore(context: container.mainContext)
        let workspace = Workspace(library: library)
        if !Self.isRunningTests {
            workspace.restore()
        }
        _library = State(initialValue: library)
        _workspace = State(initialValue: workspace)
        WindowRouter.shared.library = library
        WindowRouter.shared.workspace = workspace
        // Start checking for new builds as soon as Sheaf opens.
        _ = Updater.shared
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
        .defaultLaunchBehavior(Self.isRunningTests ? .suppressed : .automatic)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { SheafCommands(workspace: workspace) }
    }
}
