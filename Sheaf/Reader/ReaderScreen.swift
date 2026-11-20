import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// An open PDF on screen: asks for a password if it has one, then shows the
/// reader. The loading itself happens in `OpenDocument`.
struct ReaderScreen: View {
    let document: OpenDocument

    @Environment(Workspace.self) private var workspace
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            switch document.phase {
            case .loading:
                DelayedProgressView()
            case .downloading:
                DownloadingView()
            case .locked:
                UnlockView { document.unlock(with: $0) }
            case .ready(let model):
                ReaderLayout(model: model, document: document)
            case .failed(let title, let message):
                VStack(spacing: 14) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.inkMuted)
                    Text(title).font(Theme.display(20)).foregroundStyle(Theme.ink)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    PrimaryButton(title: "Back to Library") { workspace.close(document.id) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 480)
        .background(Theme.background)
        .navigationTitle(document.title)
        .toolbar {
            if document.model == nil {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 12) {
                        SquareIconButton(label: "Back to library (\u{21E7}\u{2318}L)", systemImage: "chevron.left") {
                            workspace.showLibrary()
                        }
                        Text(document.title)
                            .font(Theme.display(15))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                }
                .plainBackground()
            }
        }
        .sheafHeader()
        // PDFs dropped from Finder open here (and join the library); the PDFs
        // in dropped folders join the library.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { LibraryStore.isPDF($0) || LibraryStore.isFolder($0) }
            guard !files.isEmpty else { return false }
            WindowRouter.shared.open(urls: files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A spinner that appears only if loading takes a moment, so quick loads
/// don't flash it.
private struct DelayedProgressView: View {
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .opacity(isShown ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(Theme.hoverAnimation) { isShown = true }
            }
    }
}

/// Header, thumbnail strip, page and Highlights panel (C · Reader mockup).
struct ReaderLayout: View {
    @Bindable var model: ReaderModel
    let document: OpenDocument

    @Environment(Workspace.self) private var workspace
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ReaderModel.darkPagesKey) private var darkPages = false
    @State private var width: CGFloat = 1280
    @State private var pageEntry = ""
    @FocusState private var isSearchFocused: Bool

    private var isFocusMode: Bool { workspace.isFocusMode }
    /// The side panels sit beside the page when there's room; in a narrow
    /// window their buttons show them over the page instead.
    private var panels: ReaderPanels { workspace.readerPanels }

    // What the header shows at each width, so nothing is pushed into the
    // toolbar's overflow menu, down to half a laptop screen. Below each
    // width the control goes, in this order; the menus and shortcuts still
    // do what it does.
    private var showsPenNames: Bool { width >= 1540 }
    private var showsZoom: Bool { width >= 1300 }
    private var showsLayoutSwitch: Bool { width >= 1100 }
    private var showsPickedPenName: Bool { width >= 860 }
    private var showsFocusButton: Bool { width >= 860 || isFocusMode }
    private var showsSearchButton: Bool { width >= 760 }
    /// The highlighters and the controls on the right at their full size
    /// (they never shrink), as last laid out.
    @State private var penPickerWidth: CGFloat = 204
    @State private var controlsWidth: CGFloat = 250
    /// The title gets the header's spare room: the window less the traffic
    /// lights, the two buttons beside the title, the other controls and the
    /// gaps between them. In a narrow window it's cut short (the menu's
    /// tooltip and Rename… show all of it).
    private var titleWidth: CGFloat {
        min(280, max(90, width - 236 - penPickerWidth - controlsWidth))
    }

    var body: some View {
        HStack(spacing: 0) {
            if panels.isBeside(.pages) && !isFocusMode {
                PageStrip(model: model)
                Hairline(axis: .vertical)
            }
            pageArea
                .panelOverlay(isPresented: panels.isOver(.pages) && !isFocusMode, edge: .leading) {
                    panels.closeOverlay()
                } panel: {
                    PageStrip(model: model)
                }
                .panelOverlay(isPresented: panels.isOver(.highlights) && !isFocusMode, edge: .trailing) {
                    panels.closeOverlay()
                } panel: {
                    rightPanel
                }
            if panels.isBeside(.highlights) && !isFocusMode {
                Hairline(axis: .vertical)
                rightPanel
            }
        }
        .overlay(alignment: .top) { Hairline() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            width = $0
            panels.setWidth($0)
        }
        .onChange(of: isFocusMode) { panels.closeOverlay() }
        .navigationTitle(model.title)
        .toolbar { header }
        .task(id: model.searchQuery) {
            // Wait for a pause in typing before searching.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            model.search()
        }
        .onChange(of: model.searchFocusRequest) {
            model.isSearchBarVisible = true
            isSearchFocused = true
        }
        .alert("Go to Page", isPresented: $model.isGoToPagePresented) {
            TextField("Page", text: $pageEntry)
            Button("Go") {
                // A printed page number ("xii", "245") or one counted from the start.
                if !model.goToPage(typed: pageEntry) { NSSound.beep() }
                pageEntry = ""
            }
            Button("Cancel", role: .cancel) { pageEntry = "" }
        } message: {
            Text(model.goToPagePrompt)
        }
        .onChange(of: darkPages) { model.applyPageColors() }
        .task {
            model.undoManager = undoManager
            // Dark Pages may have been switched while another PDF was on screen.
            model.applyPageColors()
            model.restoreReadingPosition()
            model.startBackgroundWork()
            model.pdfView.onEscape = { [workspace] in
                // Esc first puts away a panel shown over the page.
                if workspace.readerPanels.closeOverlay() { return true }
                guard workspace.isFocusMode else { return false }
                workspace.isFocusMode = false
                return true
            }
        }
        .task(id: document.pendingHighlightID) {
            // Opened from a highlight in the library: scroll to it.
            guard let id = document.pendingHighlightID else { return }
            await Task.yield()
            if let record = model.highlight(id: id) { model.go(to: record) }
            document.pendingHighlightID = nil
        }
        .task(id: document.pendingPageIndex) {
            // Opened from a search match in the library: go to its page.
            guard let index = document.pendingPageIndex else { return }
            await Task.yield()
            model.goToPage(number: index + 1)
            document.pendingPageIndex = nil
        }
        .onDisappear {
            model.suspend()
            panels.closeOverlay()
        }
    }

    /// Highlights, or the search results while searching.
    private var rightPanel: some View {
        Group {
            if model.isShowingSearchResults {
                SearchResultsPanel(model: model)
                    .transition(.opacity)
            } else {
                HighlightsPanel(model: model)
                    .transition(.opacity)
            }
        }
        .frame(width: 312)
        .animation(Theme.motion, value: model.isShowingSearchResults)
    }

    private var pageArea: some View {
        PDFKitView(pdfView: model.pdfView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageCanvas)
            .overlay(alignment: .top) {
                ZStack {
                    if model.isSearchBarVisible {
                        FindBar(model: model, isFocused: $isSearchFocused)
                            .padding(.top, 12)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(Theme.motion, value: model.isSearchBarVisible)
            }
            .overlay(alignment: .bottomLeading) {
                ZStack {
                    if let page = model.backPageLabel {
                        Button(action: model.goBack) {
                            Label("Back to page \(page)", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(Theme.raised, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.control, lineWidth: 1))
                        }
                        .buttonStyle(.sheaf(.overlay, in: Capsule()))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                        .help("Go back to where you were (\u{2318}[)")
                        .padding(14)
                        .transition(.opacity)
                    }
                }
                .animation(Theme.motion, value: model.backPageNumber)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let notice = model.pageNotice {
                        PageNotice(text: notice, dismiss: model.dismissPageNotice)
                            .transition(.opacity)
                    }
                    if let error = model.saveError {
                        Text(error)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.control))
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                // Above the Back button in the corner, when it shows.
                .padding(.bottom, model.backPageNumber == nil ? 14 : 60)
                .animation(Theme.motion, value: model.saveError)
                .animation(Theme.motion, value: model.pageNotice)
            }
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var header: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    if !isFocusMode {
                        SquareIconButton(
                            label: panels.isShowing(.pages) ? "Hide pages and contents (\u{2325}\u{2318}1)" : "Show pages and contents (\u{2325}\u{2318}1)",
                            systemImage: "sidebar.left",
                            isOn: panels.isOver(.pages)
                        ) { panels.toggle(.pages) }
                    }
                    SquareIconButton(label: "Back to library (\u{21E7}\u{2318}L)", systemImage: "chevron.left") {
                        workspace.showLibrary()
                    }
                }
                ReaderTitleMenu(model: model)
                    .frame(maxWidth: titleWidth, alignment: .leading)
            }
        }
        .plainBackground()

        ToolbarItem(placement: .principal) {
            PenPicker(model: model, compact: !showsPenNames, showsPickedName: showsPickedPenName)
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { penPickerWidth = $0 }
        }
        .plainBackground()

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if showsLayoutSwitch {
                    LayoutSwitch(model: model)
                }
                PagePill(model: model)
                if showsZoom {
                    ZoomPill(model: model)
                }
                if showsSearchButton {
                    SquareIconButton(label: "Search in this PDF (\u{2318}F)", systemImage: "magnifyingglass", isOn: model.isSearchBarVisible) {
                        if model.isSearchBarVisible {
                            model.closeSearch()
                        } else {
                            model.searchFocusRequest += 1
                        }
                    }
                }
                if showsFocusButton {
                    SquareIconButton(
                        label: isFocusMode ? "Leave focus mode (Esc)" : "Focus mode: only the page, full screen (\u{21E7}\u{2318}F)",
                        systemImage: isFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        isOn: isFocusMode
                    ) { workspace.isFocusMode.toggle() }
                }
                if !isFocusMode {
                    SquareIconButton(
                        label: panels.isShowing(.highlights) ? "Hide highlights panel (\u{2325}\u{2318}2)" : "Show highlights panel (\u{2325}\u{2318}2)",
                        systemImage: "sidebar.right",
                        isOn: panels.isOver(.highlights)
                    ) { panels.toggle(.highlights) }
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0 }
        }
        .plainBackground()
    }
}
