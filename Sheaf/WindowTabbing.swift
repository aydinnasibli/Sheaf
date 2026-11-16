import AppKit
import SwiftUI

/// Keeps Sheaf in one tabbed window: the library is the first tab and each
/// PDF opens as a tab next to it, like a web browser. These are macOS's own
/// window tabs, so a tab can still be dragged out into its own window.
enum SheafWindows {
    static let tabbingIdentifier = "com.aydinnasibli.sheaf.main"

    enum Role {
        case library
        case reader
    }

    static func configure(_ window: NSWindow, as role: Role) {
        window.tabbingIdentifier = tabbingIdentifier
        window.tabbingMode = .preferred

        // A new PDF joins the window the reader is looking at, or failing
        // that any other Sheaf window. If it's the only window, it stays alone.
        guard role == .reader, (window.tabbedWindows?.count ?? 1) <= 1 else { return }
        let others = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.tabbingIdentifier == tabbingIdentifier
        }
        guard let host = others.first(where: \.isKeyWindow) ?? others.first(where: \.isMainWindow) ?? others.first else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Add as a background to a window's root view so the window joins Sheaf's tabs.
struct TabbedWindowJoiner: NSViewRepresentable {
    let role: SheafWindows.Role

    func makeNSView(context: Context) -> NSView { JoinerView(role: role) }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class JoinerView: NSView {
        private let role: SheafWindows.Role
        private var didConfigure = false

        init(role: SheafWindows.Role) {
            self.role = role
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not used from Interface Builder") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !didConfigure, let window else { return }
            didConfigure = true
            SheafWindows.configure(window, as: role)
        }
    }
}
