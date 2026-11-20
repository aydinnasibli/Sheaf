import AppKit
import SwiftUI

/// The system share picker (AirDrop, Mail, Messages, Notes…) for PDF files,
/// as Preview shows it.
enum SharePicker {
    /// The readers' titles, which the picker points at when the PDF on
    /// screen is shared from the menu bar. Added by the title menus; there's
    /// one in each window showing a PDF.
    private static let readerTitleViews = NSHashTable<NSView>.weakObjects()

    static func addReaderTitle(_ view: NSView) {
        readerTitleViews.add(view)
    }

    /// The reader's title in the window in front, if it shows a PDF.
    private static var frontReaderTitle: NSView? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return nil }
        return readerTitleViews.allObjects.first { $0.window === window }
    }

    /// Shows the picker pointing at `view`; without one, at the reader's
    /// title if it's on screen, or else at the pointer (or the top of the
    /// window, if the pointer is outside it).
    static func show(_ urls: [URL], from view: NSView? = nil) {
        guard !urls.isEmpty else { return }
        // After the menu that asked for it has closed.
        Task { @MainActor in
            let picker = NSSharingServicePicker(items: urls)
            if let anchor = view ?? frontReaderTitle, anchor.window?.isVisible == true {
                picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
            } else if let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView {
                picker.show(relativeTo: pointerRect(in: content, of: window), of: content, preferredEdge: content.isFlipped ? .maxY : .minY)
            }
        }
    }

    /// A point-sized rectangle under the pointer, or at the top middle of
    /// the window's content if the pointer is elsewhere (in the menu bar).
    private static func pointerRect(in content: NSView, of window: NSWindow) -> CGRect {
        let layout = window.contentLayoutRect
        var point = window.mouseLocationOutsideOfEventStream
        if !layout.contains(point) {
            point = CGPoint(x: layout.midX, y: layout.maxY - 4)
        }
        let local = content.convert(point, from: nil)
        return CGRect(x: local.x, y: local.y, width: 1, height: 1)
    }
}

/// Reports the AppKit view behind a SwiftUI view, to point a popover at.
struct AnchorViewReader: NSViewRepresentable {
    let onChange: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onChange(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
