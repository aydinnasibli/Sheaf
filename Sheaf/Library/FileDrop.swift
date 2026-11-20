import SwiftUI
import UniformTypeIdentifiers

/// Accepts PDFs and folders dragged in from Finder or another app, but not
/// rows dragged within the library's own list (they're already in it).
struct FileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    /// Gets the dropped PDFs and folders; other files are left out.
    let perform: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !info.hasItemsConforming(to: [.sheafLibraryPDF])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            let files = urls.filter { LibraryStore.isPDF($0) || LibraryStore.isFolder($0) }
            if !files.isEmpty { perform(files) }
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
