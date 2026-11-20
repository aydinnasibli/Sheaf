import AppKit
import Observation
import SwiftUI

/// One of Sheaf's windows for reading: the main window (the library, or a
/// PDF from its "Open now" list) or a PDF's own window, opened to read two
/// PDFs side by side. Each has its own side panels and its own focus mode,
/// and the menu bar acts on the one in front (see `SheafCommands`).
@Observable
final class ReaderWindow {
    enum Kind: Hashable {
        case main
        /// A PDF's own window, by the PDF's library ID.
        case pdf(UUID)
    }

    let kind: Kind
    /// The side panels beside or over the page. Each window has its own,
    /// since each has its own width.
    let panels: ReaderPanels
    /// Focus mode: only the page, full screen, with the side panels hidden.
    var isFocusMode = false
    /// The window's undo manager, so removing a PDF from its own window can
    /// be undone in the main window after that window has closed.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The AppKit window it's shown in, once it's on screen.
    @ObservationIgnored weak var nsWindow: NSWindow?

    init(kind: Kind, panels: ReaderPanels = ReaderPanels()) {
        self.kind = kind
        self.panels = panels
    }

    var isMain: Bool { kind == .main }
}

/// The reading window in front: the key window, or the window that the key
/// sheet or popover belongs to. It's `nil` while Help, Settings, an Open or
/// Save panel, or no window at all is in front, so the menus and shortcuts
/// for a PDF or the library leave the windows behind alone (see
/// `SheafCommands`), and Control-Tab doesn't switch the main window's PDFs.
@Observable
final class FrontReaderWindow {
    static let shared = FrontReaderWindow()

    private(set) var window: ReaderWindow?
    /// Goes up each time the menu bar opens, so the Edit menu's spelling
    /// and substitution items show the text field's settings then.
    private(set) var menuOpenings = 0

    @ObservationIgnored private var windows: [WeakWindow] = []
    /// Popovers' windows, and the window each points into.
    @ObservationIgnored private var popovers: [WeakPopover] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private struct WeakWindow {
        weak var state: ReaderWindow?
    }

    private struct WeakPopover {
        weak var popover: NSWindow?
        weak var owner: NSWindow?
    }

    private init() {
        let center = NotificationCenter.default
        // A window that's going away, or no longer key, isn't the one in
        // front, even if AppKit hasn't picked the next one yet.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let leaving = name == NSWindow.didBecomeKeyNotification ? nil : (notification.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.update(leaving: leaving) }
            })
        }
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            let menu = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let mainMenu = NSApp.mainMenu, menu == ObjectIdentifier(mainMenu) else { return }
                self.menuOpenings += 1
            }
        })
    }

    /// Called by each reading window once it knows its AppKit window.
    func register(_ state: ReaderWindow, in window: NSWindow?) {
        state.nsWindow = window
        windows.removeAll { $0.state == nil || $0.state === state }
        windows.append(WeakWindow(state: state))
        update()
    }

    /// Called when a popover shows over a window (see `PagePopover`): typing
    /// a note in it keeps the menus on that window.
    func attach(popover: NSWindow?, to owner: NSWindow?) {
        popovers.removeAll { $0.popover == nil || $0.popover === popover }
        guard let popover, let owner else { return }
        popovers.append(WeakPopover(popover: popover, owner: owner))
        update()
    }

    private func update(leaving: ObjectIdentifier? = nil) {
        var key = NSApp.keyWindow
        if let current = key, ObjectIdentifier(current) == leaving { key = nil }
        let found = key.flatMap(readingWindow(owning:)).flatMap { owner in
            windows.lazy.compactMap(\.state).first { $0.nsWindow === owner }
        }
        if found !== window { window = found }
    }

    /// The window a sheet, alert or popover belongs to, or the window itself.
    private func readingWindow(owning window: NSWindow) -> NSWindow {
        var owner = window
        // A few steps at most: a popover over a sheet over a window.
        for _ in 0..<8 {
            guard let next = owner.sheetParent ?? owner.parent ?? popovers.first(where: { $0.popover === owner })?.owner,
                  next !== owner
            else { break }
            owner = next
        }
        return owner
    }
}

extension View {
    /// What every reading window does around what it shows; see `ReaderWindowModifier`.
    func readerWindow(_ state: ReaderWindow, onClose: @escaping () -> Void = {}) -> some View {
        modifier(ReaderWindowModifier(state: state, onClose: onClose))
    }
}

/// What the main window and each PDF's own window share: the library's
/// notices, the PDF commands' questions, focus mode in full screen, and
/// telling the menu bar and the workspace which window is in front.
struct ReaderWindowModifier: ViewModifier {
    let state: ReaderWindow
    /// Called when the window closes (not when Sheaf quits).
    let onClose: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.undoManager) private var undoManager
    @State private var window: NSWindow?
    /// Whether focus mode put the window in full screen, so leaving focus
    /// mode only leaves full screen if focus mode entered it.
    @State private var focusEnteredFullScreen = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { LibraryNotice() }
            // Narrow enough to fill half of a 13-inch laptop screen when tiled.
            .frame(minWidth: 680, minHeight: 480)
            .modifier(PDFActionAlerts())
            // In full screen the header slides away and comes back when the
            // pointer reaches the top of the screen, as in Preview and Books.
            .windowToolbarFullScreenVisibility(.onHover)
            .environment(state)
            .background(WindowReader { window in
                self.window = window
                FrontReaderWindow.shared.register(state, in: window)
                // It may have come to the front before it could say so.
                if window?.isKeyWindow == true { workspace.frontWindow = state.kind }
            })
            .onChange(of: undoManager, initial: true) { state.undoManager = undoManager }
            .onChange(of: state.isFocusMode) { _, isFocused in
                matchFullScreen(to: isFocused)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
                // Leaving full screen (green button, ⌃⌘F) also ends focus mode.
                guard isThisWindow(notification) else { return }
                focusEnteredFullScreen = false
                state.isFocusMode = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard isThisWindow(notification) else { return }
                workspace.frontWindow = state.kind
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard isThisWindow(notification) else { return }
                onClose()
            }
    }

    private func isThisWindow(_ notification: Notification) -> Bool {
        guard let window else { return false }
        return notification.object as? NSWindow === window
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
struct WindowReader: NSViewRepresentable {
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
