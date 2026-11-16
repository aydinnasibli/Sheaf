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

        switch role {
        case .reader:
            join(window, attemptsLeft: 4)
        case .library:
            // When Sheaf starts because a PDF was double-clicked, the PDF's
            // window can appear before the library's. Pull it in as a tab.
            Task { @MainActor in
                await Task.yield()
                gatherLoneWindows(into: window)
            }
        }
    }

    /// Adds a new PDF window as a tab of the window the reader is looking at,
    /// or any other Sheaf window. If none is on screen yet, tries again shortly.
    private static func join(_ window: NSWindow, attemptsLeft: Int) {
        guard (window.tabbedWindows?.count ?? 1) <= 1 else { return }
        let others = otherSheafWindows(than: window)
        if let host = others.first(where: \.isKeyWindow) ?? others.first(where: \.isMainWindow) ?? others.first {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else if attemptsLeft > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                join(window, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    private static func gatherLoneWindows(into library: NSWindow) {
        guard library.isVisible else { return }
        let loners = otherSheafWindows(than: library).filter { ($0.tabbedWindows?.count ?? 1) <= 1 }
        guard let front = loners.last else { return }
        for window in loners {
            library.addTabbedWindow(window, ordered: .above)
        }
        front.makeKeyAndOrderFront(nil)
    }

    private static func otherSheafWindows(than window: NSWindow) -> [NSWindow] {
        NSApp.windows.filter { $0 !== window && $0.isVisible && $0.tabbingIdentifier == tabbingIdentifier }
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
