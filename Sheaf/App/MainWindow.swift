import AppKit
import Observation
import PDFKit
import SwiftUI

/// The app's single window: the library, or the PDF that's open on screen.
struct MainWindow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @State private var window: NSWindow?
    /// Whether focus mode put the window in full screen, so leaving focus
    /// mode only leaves full screen if focus mode entered it.
    @State private var focusEnteredFullScreen = false

    var body: some View {
        Group {
            if let document = workspace.selectedDocument {
                ReaderScreen(document: document)
                    .id(document.id)
            } else {
                LibraryScreen()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        // In full screen the header slides away and comes back when the
        // pointer reaches the top of the screen, as in Preview and Books.
        .windowToolbarFullScreenVisibility(.onHover)
        .background(WindowReader { window = $0 })
        .onAppear { WindowRouter.shared.attach(openWindow) }
        .onChange(of: workspace.isFocusMode) { _, isFocused in
            matchFullScreen(to: isFocused)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            // Leaving full screen (green button, ⌃⌘F) also ends focus mode.
            guard let window, notification.object as? NSWindow === window else { return }
            focusEnteredFullScreen = false
            workspace.isFocusMode = false
        }
    }

    private func matchFullScreen(to isFocused: Bool) {
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if isFocused && !isFullScreen {
            focusEnteredFullScreen = true
            window.toggleFullScreen(nil)
        } else if !isFocused && isFullScreen && focusEnteredFullScreen {
            focusEnteredFullScreen = false
            window.toggleFullScreen(nil)
        }
    }
}

/// Reports the window a SwiftUI view is in.
private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onChange] in onChange?(window) }
        }
    }
}
