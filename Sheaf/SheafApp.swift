import SwiftData
import SwiftUI

@main
struct SheafApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var library: LibraryStore

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
        _library = State(initialValue: library)
        WindowRouter.shared.library = library
    }

    var body: some Scene {
        // Listed first, so it's the window Sheaf opens at launch. PDFs open
        // as tabs next to it (see SheafWindows).
        Window("Library", id: "library") {
            LibraryWindow()
                .environment(library)
                .modelContainer(container)
                .frame(minWidth: 760, minHeight: 480)
                .background(TabbedWindowJoiner(role: .library))
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .commands { ReaderCommands() }

        WindowGroup("PDF", id: "reader", for: UUID.self) { $entryID in
            ReaderScreen(entryID: entryID)
                .environment(library)
                .modelContainer(container)
                .background(TabbedWindowJoiner(role: .reader))
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
