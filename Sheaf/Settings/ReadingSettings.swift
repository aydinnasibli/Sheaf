import Foundation
import Observation

/// The reading settings in Settings > Reading: page layout, zoom, book
/// spreads and dark pages.
///
/// There's one copy of each, in the preferences the reader already uses
/// (`ReaderModel.layoutKey` and friends). The reader saves a setting whenever
/// it changes in the View menu or the toolbar, and this reads the same keys,
/// so Settings always shows what the menus show. Changing a setting here also
/// changes the PDFs that are open, so the menus keep agreeing with Settings.
@Observable
final class ReadingSettings {
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let openReaders: () -> [ReaderModel]
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    /// Bumped when any preference changes, so views showing these settings
    /// redraw after a change made in the View menu or the toolbar.
    private var revision = 0

    init(preferences: UserDefaults = .standard, openReaders: @escaping () -> [ReaderModel]) {
        self.preferences = preferences
        self.openReaders = openReaders
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: preferences, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The layout new PDFs open in.
    var layout: ReaderModel.PageLayout {
        get {
            _ = revision
            return preferences.string(forKey: ReaderModel.layoutKey).flatMap(ReaderModel.PageLayout.init) ?? .scroll
        }
        set {
            // Until a zoom is picked, the zoom follows the layout (see
            // `zoomMode`); keep it as it was, since only the layout changed.
            if preferences.string(forKey: ReaderModel.zoomModeKey) == nil {
                preferences.set(zoomMode.rawValue, forKey: ReaderModel.zoomModeKey)
            }
            preferences.set(newValue.rawValue, forKey: ReaderModel.layoutKey)
            for reader in openReaders() { reader.layout = newValue }
        }
    }

    /// Fit Page or Fit Width. Until one is picked, new PDFs fill the width
    /// in the scrolling layouts and fit the page in the others, as
    /// `ReaderModel.init` does.
    var zoomMode: ReaderModel.ZoomMode {
        get {
            _ = revision
            if let saved = preferences.string(forKey: ReaderModel.zoomModeKey).flatMap(ReaderModel.ZoomMode.init),
               saved != .custom {
                return saved
            }
            return !layout.showsPairs && layout != .single ? .fitWidth : .fitPage
        }
        set {
            guard newValue != .custom else { return }
            preferences.set(newValue.rawValue, forKey: ReaderModel.zoomModeKey)
            for reader in openReaders() {
                if newValue == .fitWidth { reader.zoomToWidth() } else { reader.zoomToFit() }
            }
        }
    }

    /// In the two-page layouts, the cover stands alone.
    var showsBookSpreads: Bool {
        get {
            _ = revision
            return preferences.bool(forKey: ReaderModel.bookSpreadsKey)
        }
        set {
            preferences.set(newValue, forKey: ReaderModel.bookSpreadsKey)
            for reader in openReaders() { reader.showsBookSpreads = newValue }
        }
    }

    /// Dark pages while the Mac is in Dark Mode. The reader on screen watches
    /// this preference itself, and the others catch up when they're shown.
    var darkPages: Bool {
        get {
            _ = revision
            return preferences.bool(forKey: ReaderModel.darkPagesKey)
        }
        set { preferences.set(newValue, forKey: ReaderModel.darkPagesKey) }
    }
}
