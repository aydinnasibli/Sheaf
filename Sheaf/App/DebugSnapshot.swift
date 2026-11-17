#if DEBUG
import AppKit

/// Debug builds only: draws Sheaf's window into a PNG when another process
/// asks, so changes can be checked without bringing Sheaf to the front.
///
/// Post the distributed notification `sheaf.debug.snapshot` (see
/// `Scripts/snapshot.swift`). The sandbox strips anything sent with it, and
/// only lets Sheaf write inside its container, so the picture is saved as
/// `sheaf-window.png` in Sheaf's temporary folder:
/// `~/Library/Containers/com.aydinnasibli.sheaf/Data/tmp/`.
enum DebugSnapshot {
    static func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("sheaf.debug.snapshot"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { write() }
        }
    }

    private static func write() {
        let url = FileManager.default.temporaryDirectory.appending(path: "sheaf-window.png")
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
              // The frame view holds the toolbar as well as the content.
              let frameView = window.contentView?.superview,
              let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else {
            NSLog("Sheaf snapshot: no window to draw")
            return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            NSLog("Sheaf snapshot: couldn't write \(url.path): \(error)")
        }
    }
}
#endif
