import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// An open PDF on screen: asks for a password if it has one, then shows the
/// reader. The loading itself happens in `OpenDocument`.
struct ReaderScreen: View {
    let document: OpenDocument

    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            switch document.phase {
            case .loading:
                DelayedProgressView()
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
        .frame(minWidth: 720, minHeight: 480)
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
    @AppStorage("showsThumbnails") private var showsThumbnails = true
    @AppStorage("showsHighlightsPanel") private var showsPanel = true
    @State private var width: CGFloat = 1280
    @State private var pageEntry = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showsThumbnails && width >= 900 {
                PageStrip(model: model)
                Hairline(axis: .vertical)
            }
            pageArea
            if showsPanel && width >= 760 {
                Hairline(axis: .vertical)
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
        }
        .overlay(alignment: .top) { Hairline() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
            TextField("Page number", text: $pageEntry)
            Button("Go") {
                if let number = Int(pageEntry.trimmingCharacters(in: .whitespaces)) {
                    model.goToPage(number: number)
                }
                pageEntry = ""
            }
            Button("Cancel", role: .cancel) { pageEntry = "" }
        } message: {
            Text("Enter a page number from 1 to \(model.pageCount).")
        }
        .task {
            model.undoManager = undoManager
            model.restoreReadingPosition()
        }
        .task(id: document.pendingHighlightID) {
            // Opened from a highlight in the library: scroll to it.
            guard let id = document.pendingHighlightID else { return }
            await Task.yield()
            if let record = model.highlight(id: id) { model.go(to: record) }
            document.pendingHighlightID = nil
        }
        .onDisappear { model.suspend() }
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
            .overlay(alignment: .bottom) {
                ZStack {
                    if let error = model.saveError {
                        Text(error)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.control))
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                            .padding(.bottom, 14)
                            .transition(.opacity)
                    }
                }
                .animation(Theme.motion, value: model.saveError)
            }
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var header: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 12) {
                SquareIconButton(label: "Back to library (\u{21E7}\u{2318}L)", systemImage: "chevron.left") {
                    workspace.showLibrary()
                }
                TitleBlock(model: model)
            }
        }
        .plainBackground()

        ToolbarItem(placement: .principal) {
            PenPicker(model: model, compact: width < 1240)
        }
        .plainBackground()

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                if width >= 1000 {
                    LayoutSwitch(model: model)
                }
                PagePill(model: model)
                if width >= 1100 {
                    ZoomPill(model: model)
                }
                SquareIconButton(label: "Search in this PDF (\u{2318}F)", systemImage: "magnifyingglass", isOn: model.isSearchBarVisible) {
                    if model.isSearchBarVisible {
                        model.closeSearch()
                    } else {
                        model.searchFocusRequest += 1
                    }
                }
            }
        }
        .plainBackground()
    }
}
