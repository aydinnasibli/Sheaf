import AppKit
import SwiftUI

/// The PDF's title in the reader's header. Clicking it opens a menu, like
/// the title menus of Preview and Pages: rename, show in Finder, share,
/// open in its own window (or back in the main window), and where the file is.
struct ReaderTitleMenu: View {
    let model: ReaderModel

    @Environment(Workspace.self) private var workspace
    @Environment(ReaderWindow.self) private var readerWindow
    @State private var anchor: NSView?

    var body: some View {
        Menu {
            if let entry = model.entry, entry.isInLibrary {
                Button("Rename\u{2026}") { workspace.requestRename(entry) }
                Button("Show in Finder") { workspace.showInFinder([entry]) }
                Button("Share\u{2026}") { workspace.share([entry], from: anchor) }
                Divider()
                // To read it beside another PDF, and back.
                if readerWindow.isMain {
                    Button("Open in New Window") { workspace.openInNewWindow(entry) }
                } else {
                    Button("Move to Main Window") { workspace.moveToMainWindow(entry.id) }
                }
                Divider()
                Section("Location") {
                    location(of: URL(filePath: entry.lastKnownPath))
                }
            }
        } label: {
            HStack(spacing: 6) {
                TitleBlock(model: model)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.sheaf(cornerRadius: 8))
        .background(AnchorViewReader { view in
            anchor = view
            // File › Share… points the picker here while the PDF is on screen.
            SharePicker.addReaderTitle(view)
        })
        // The whole title, which a narrow window cuts short.
        .help("\u{201C}\(model.title)\u{201D}: click to rename, show in Finder or share it")
        .accessibilityLabel(model.title)
        .accessibilityHint("Shows a menu to rename, show in Finder or share this PDF")
    }

    /// The folder the file is in, opening onto every folder above it, as
    /// Command-clicking a document's title does in other Mac apps. Picking a
    /// folder shows it in Finder.
    @ViewBuilder
    private func location(of file: URL) -> some View {
        let folders = Self.folders(containing: file)
        if let first = folders.first {
            Menu {
                ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                    Button {
                        // Shows the folder with the item inside it selected.
                        NSWorkspace.shared.activateFileViewerSelecting([index == 0 ? file : folders[index - 1]])
                    } label: {
                        Label(Self.name(of: folder), systemImage: index == folders.count - 1 ? "internaldrive" : "folder")
                    }
                }
            } label: {
                Label(Self.name(of: first), systemImage: "folder")
            }
        }
    }

    /// The folders a file is in, from its own folder up to the disk.
    static func folders(containing file: URL) -> [URL] {
        var folders: [URL] = []
        var folder = file.deletingLastPathComponent().standardizedFileURL
        while true {
            folders.append(folder)
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            guard parent.path(percentEncoded: false) != folder.path(percentEncoded: false) else { break }
            folder = parent
        }
        return folders
    }

    /// The name Finder shows for a folder ("Macintosh HD" for the disk).
    private static func name(of folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
    }
}
