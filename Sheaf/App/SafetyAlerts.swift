import AppKit
import SwiftData

/// Alerts that explain what happened to highlights when something goes
/// wrong: the library won't open, or quitting would interrupt a save.
enum SafetyAlerts {
    /// At launch, when the library couldn't be opened and Sheaf is using a
    /// temporary one.
    static func showLibraryCouldNotOpen() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sheaf Couldn\u{2019}t Open Your Library"
        alert.informativeText = """
            Your highlights and notes are still saved in your PDF files, and Sheaf keeps backups of your library.

            Until Sheaf is opened again, it\u{2019}s using a temporary library and won\u{2019}t write anything into your PDF files. Highlights you make now won\u{2019}t be kept after you quit.
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Backups")
        if alert.runModal() == .alertSecondButtonReturn {
            let backups = LibraryBackup.folder(for: ModelConfiguration(isStoredInMemoryOnly: false).url)
            NSWorkspace.shared.activateFileViewerSelecting([backups])
        }
    }

    /// When quitting has waited a while for a save that hasn't finished.
    /// Returns true to quit anyway.
    static func confirmQuitWhileSaving(fileNames: [String]) -> Bool {
        let files = switch fileNames.count {
        case 0: "a PDF"
        case 1: "\u{201C}\(fileNames[0])\u{201D}"
        default: "\(fileNames.count) PDFs"
        }
        let later = fileNames.count > 1 ? "into the files the next time you open them" : "into the file the next time you open it"
        let alert = NSAlert()
        alert.messageText = "Quit Anyway?"
        alert.informativeText = "Sheaf is still saving highlights into \(files). They\u{2019}re safe in Sheaf\u{2019}s library, and Sheaf will write them \(later)."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
