import SwiftData
import SwiftUI

@main
struct SheafApp: App {
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
        _library = State(initialValue: LibraryStore(context: container.mainContext))
    }

    var body: some Scene {
        // Listed first, so it's the window Sheaf opens at launch.
        Window("Library", id: "library") {
            LibraryWindow()
                .environment(library)
                .modelContainer(container)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1180, height: 760)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .commands { ReaderCommands() }

        // Each PDF opens in its own window, like Preview. macOS supplies
        // File > Open, Open Recent, window tabs and Finder's "Open With".
        DocumentGroup(viewing: PDFFile.self) { file in
            ReaderView(data: file.document.data, fileURL: file.fileURL)
                .environment(library)
                .modelContainer(container)
        }
        .defaultSize(width: 1100, height: 1000)
    }
}
