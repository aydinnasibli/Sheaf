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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Layout

/// Header, thumbnail strip, page and Highlights panel (C · Reader mockup).
private struct ReaderLayout: View {
    @Bindable var model: ReaderModel
    let document: OpenDocument

    @Environment(Workspace.self) private var workspace
    @Environment(\.undoManager) private var undoManager
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
                    } else {
                        HighlightsPanel(model: model)
                    }
                }
                .frame(width: 312)
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
                if model.isSearchBarVisible {
                    FindBar(model: model, isFocused: $isSearchFocused)
                        .padding(.top, 12)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = model.saveError {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.control))
                        .padding(.bottom, 14)
                }
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

private struct TitleBlock: View {
    let model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.title)
                .font(Theme.display(15))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let collection = model.entry?.collection {
                    Swatch(color: Theme.collectionColor(collection.colorIndex), size: 8)
                    Text(collection.name)
                } else {
                    Text(model.pageCount == 1 ? "1 page" : "\(model.pageCount) pages")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.inkMuted)
            .lineLimit(1)
        }
        .frame(maxWidth: 250, alignment: .leading)
    }
}

/// The four highlighters. Compact mode shows a label only on the picked one.
private struct PenPicker: View {
    let model: ReaderModel
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(HighlightKind.allCases) { kind in
                let isActive = model.activePen == kind
                Button { model.choosePen(kind) } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(kind.swatch)
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.12), lineWidth: 1))
                        if !compact || isActive {
                            Text(kind.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            if !compact {
                                Text(String(kind.rawValue))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.inkMuted)
                            }
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, !compact || isActive ? 10 : 8)
                    .frame(height: 30)
                    .background(isActive ? Theme.penActive : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 2))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("\(kind.name) highlighter: select text, then press \(kind.rawValue)")
                .accessibilityLabel("\(kind.name) highlighter")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Single / Two pages / Scroll. The picked layout shows its name.
private struct LayoutSwitch: View {
    @Bindable var model: ReaderModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReaderModel.PageLayout.allCases) { layout in
                let isOn = model.layout == layout
                Button { model.layout = layout } label: {
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: layout)).font(.system(size: 12, weight: .semibold))
                        if isOn {
                            Text(layout.title)
                                .font(.system(size: 12, weight: .semibold))
                                .fixedSize()
                        }
                    }
                    .fixedSize()
                    .padding(.horizontal, isOn ? 10 : 0)
                    .frame(minWidth: 34)
                    .frame(height: 28)
                    .foregroundStyle(isOn ? Theme.onAccent : Theme.inkSecondary)
                    .background(isOn ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(layout.menuTitle)
                .accessibilityLabel(layout.menuTitle)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.control, lineWidth: 1))
        .fixedSize()
    }

    private func icon(for layout: ReaderModel.PageLayout) -> String {
        switch layout {
        case .single: "rectangle.portrait"
        case .twoPages: "rectangle.split.2x1"
        case .scroll: "rectangle.split.1x2"
        }
    }
}

private struct PagePill: View {
    let model: ReaderModel

    var body: some View {
        let sideways = model.layout == .twoPages
        Pill {
            PillIconButton(label: "Previous page", systemImage: sideways ? "chevron.left" : "chevron.up", isEnabled: model.canGoToPreviousPage) {
                model.goToPreviousPage()
            }
            Button { model.isGoToPagePresented = true } label: {
                (Text(model.pageLabel).fontWeight(.semibold).foregroundStyle(Theme.ink)
                    + Text(" / \(model.pageCount)").foregroundStyle(Theme.inkMuted))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)
            .help("Go to page (\u{2325}\u{2318}G)")
            PillIconButton(label: "Next page", systemImage: sideways ? "chevron.right" : "chevron.down", isEnabled: model.canGoToNextPage) {
                model.goToNextPage()
            }
        }
    }
}

private struct ZoomPill: View {
    let model: ReaderModel

    var body: some View {
        Pill {
            PillIconButton(label: "Zoom out (\u{2318}\u{2212})", systemImage: "minus", action: model.zoomOut)
            Button {
                model.isFitToWindow ? model.zoomToActualSize() : model.zoomToFit()
            } label: {
                Text(model.isFitToWindow ? "Fit" : "\(model.zoomPercent)%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 40)
            }
            .buttonStyle(.plain)
            .help(model.isFitToWindow ? "Actual size (\u{2318}0)" : "Zoom to fit (\u{2318}9)")
            PillIconButton(label: "Zoom in (\u{2318}+)", systemImage: "plus", action: model.zoomIn)
        }
    }
}

// MARK: - Pages and contents

/// The left strip: page thumbnails, or the table of contents when the PDF
/// has one.
private struct PageStrip: View {
    let model: ReaderModel
    @AppStorage("stripShowsContents") private var showsContents = false

    private var isContents: Bool { showsContents && !model.outlineRows.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if !model.outlineRows.isEmpty {
                HStack(spacing: 2) {
                    tab("Pages", selected: !isContents) { showsContents = false }
                    tab("Contents", selected: isContents) { showsContents = true }
                }
                .padding(2)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 9))
                .padding(10)
                Hairline()
            }
            if isContents {
                ContentsList(model: model)
            } else {
                ThumbnailList(model: model)
            }
        }
        .frame(width: isContents ? 260 : 168)
        .background(Theme.sidebar)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(selected ? Theme.penActive : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The table of contents, indented by level, with the current section marked.
private struct ContentsList: View {
    let model: ReaderModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.outlineRows) { row in
                        let isCurrent = row.id == model.currentOutlineRowID
                        Button { model.go(to: row) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.title)
                                    .font(.system(size: row.depth == 0 ? 13 : 12.5, weight: row.depth == 0 || isCurrent ? .semibold : .regular))
                                    .foregroundStyle(row.depth == 0 || isCurrent ? Theme.ink : Theme.inkSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 4)
                                if let page = row.pageIndex {
                                    Text(String(page + 1))
                                        .font(.system(size: 11.5))
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.inkMuted)
                                }
                            }
                            .padding(.leading, 10 + CGFloat(min(row.depth, 4)) * 14)
                            .padding(.trailing, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(isCurrent ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isCurrent ? Theme.control : .clear, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(row.pageIndex.map { "\(row.title), page \($0 + 1)" } ?? row.title)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        .id(row.id)
                    }
                }
                .padding(8)
            }
            .onAppear {
                if let current = model.currentOutlineRowID { proxy.scrollTo(current, anchor: .center) }
            }
            .onChange(of: model.currentOutlineRowID) { _, current in
                if let current { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(current, anchor: .center) } }
            }
        }
    }
}

/// Page thumbnails with a marker beside each highlight (C · Reader mockup).
private struct ThumbnailList: View {
    let model: ReaderModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        ThumbnailCell(
                            page: model.document.page(at: index),
                            number: index + 1,
                            isCurrent: isCurrent(index),
                            markers: model.markers(onPage: index)
                        ) {
                            model.goToPage(number: index + 1)
                        }
                        .id(index)
                    }
                }
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo(model.currentPageIndex, anchor: .center) }
            .onChange(of: model.currentPageIndex) { _, index in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func isCurrent(_ index: Int) -> Bool {
        index == model.currentPageIndex || (model.layout == .twoPages && index == model.currentPageIndex + 1)
    }
}

private struct ThumbnailCell: View {
    let page: PDFPage?
    let number: Int
    let isCurrent: Bool
    let markers: [(position: Double, kind: HighlightKind)]
    let action: () -> Void

    @State private var image: NSImage?

    private var size: CGSize {
        guard let bounds = page?.bounds(for: .cropBox), bounds.width > 0 else { return CGSize(width: 108, height: 140) }
        let width: CGFloat = 108
        return CGSize(width: width, height: min(160, width * bounds.height / bounds.width))
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Color.white
                    }
                }
                .frame(width: size.width, height: size.height)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 2))
                .shadow(color: .black.opacity(isCurrent ? 0 : 0.14), radius: 2, y: 1)
                .overlay(alignment: .topTrailing) {
                    ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                        Capsule()
                            .fill(marker.kind.vivid)
                            .frame(width: 5, height: 14)
                            .offset(x: 7, y: max(0, size.height * marker.position - 7))
                    }
                }
                Text(String(number))
                    .font(.system(size: 11.5, weight: isCurrent ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Theme.ink : Theme.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(number)")
        .task {
            image = page?.thumbnail(of: CGSize(width: 216, height: 320), for: .cropBox)
        }
    }
}

// MARK: - Highlights panel

private struct HighlightsPanel: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Highlights")
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(model.highlights.count == 1 ? "1 in this PDF" : "\(model.highlights.count) in this PDF")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
            }

            FlowChips(model: model)

            if let block = model.fileWriteBlock {
                Label(block.explanation, systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.highlights.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.highlightGroups, id: \.page) { group in
                            SectionLabel(title: "Page \(group.page + 1)")
                                .padding(.top, 6)
                            ForEach(group.items) { record in
                                HighlightCard(record: record, model: model)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                export()
            } label: {
                Label("Export highlights as Markdown", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.control, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(model.highlights.isEmpty)
            .opacity(model.highlights.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No highlights yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Select text, then press 1\u{2013}4 or click a highlighter above. Pick a highlighter first to highlight as you select.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(model.title) highlights.md"
        let text = model.markdownExport()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The color filter chips with counts.
private struct FlowChips: View {
    @Bindable var model: ReaderModel

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(HighlightKind.allCases) { kind in
                let isOn = model.panelFilter.contains(kind)
                Button {
                    if isOn { model.panelFilter.remove(kind) } else { model.panelFilter.insert(kind) }
                } label: {
                    Text("\(kind.name) \u{00B7} \(model.count(of: kind))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .foregroundStyle(kind.chipText)
                        .background(kind.chipBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? Theme.accent : .clear, lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(isOn ? "Show all colors" : "Show only \(kind.name)")
                .accessibilityLabel("\(kind.name), \(model.count(of: kind))")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// A highlight in the panel. Click the text to go to it; click the note
/// (or "Add note") to type a note right on the card.
private struct HighlightCard: View {
    let record: HighlightRecord
    let model: ReaderModel

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovered = false
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Swatch(color: record.kind.swatch)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Button { model.go(to: record) } label: {
                    Text(record.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to this highlight")
                .accessibilityLabel("\(record.kind.name): \(record.text)")
                .accessibilityHint("Goes to this highlight")

                if isEditing {
                    TextField("Write a note\u{2026}", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1...6)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
                        .focused($isNoteFocused)
                        .onSubmit(commit)
                        .onExitCommand { isEditing = false }
                    Text("Return to save \u{00B7} Esc to cancel")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkMuted)
                } else if !record.note.isEmpty {
                    Button(action: startEditing) {
                        Text(record.note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.inkMuted)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit note")
                } else if isHovered {
                    Button(action: startEditing) {
                        Label("Add note", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isEditing ? Theme.control : Theme.border, lineWidth: 1))
        .onHover { isHovered = $0 }
        .onChange(of: isNoteFocused) { _, focused in
            if !focused && isEditing { commit() }
        }
        .contextMenu {
            Button(record.note.isEmpty ? "Add Note" : "Edit Note", action: startEditing)
            Menu("Change Color") {
                ForEach(HighlightKind.allCases) { kind in
                    Button(kind.name) { model.setKind(kind, for: record) }
                        .disabled(kind == record.kind)
                }
            }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            }
            Divider()
            Button("Delete Highlight", role: .destructive) { model.delete(record) }
        }
    }

    private func startEditing() {
        draft = record.note
        isEditing = true
        isNoteFocused = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        model.setNote(draft, for: record)
    }
}

// MARK: - Search

/// The find bar that drops down over the page.
private struct FindBar: View {
    @Bindable var model: ReaderModel
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.inkMuted)
            TextField("Search in PDF", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused(isFocused)
                .frame(width: 240)
                .onSubmit { model.selectNextResult() }
                .onExitCommand { model.closeSearch() }
            Text(status)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.inkMuted)
                .frame(minWidth: 70, alignment: .trailing)
            PillIconButton(label: "Previous match (\u{21E7}\u{2318}G)", systemImage: "chevron.up", isEnabled: !model.searchResults.isEmpty) {
                model.selectPreviousResult()
            }
            PillIconButton(label: "Next match (\u{2318}G)", systemImage: "chevron.down", isEnabled: !model.searchResults.isEmpty) {
                model.selectNextResult()
            }
            Button("Done") { model.closeSearch() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 6)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.control, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var status: String {
        if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if model.searchResults.isEmpty { return model.isSearching ? "Searching\u{2026}" : "No matches" }
        let position = model.selectedResultID.map { "\($0 + 1) of " } ?? ""
        return "\(position)\(model.searchResults.count)\(model.isSearching ? "+" : "")"
    }
}

private struct SearchResultsPanel: View {
    let model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search")
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.searchResults) { result in
                        let isSelected = model.selectedResultID == result.id
                        Button { model.selectResult(id: result.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Page \(result.pageLabel)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.inkMuted)
                                Text(result.snippet)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(isSelected ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(result.pageLabel): \(String(result.snippet.characters))")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .overlay {
                if model.searchResults.isEmpty && !model.isSearching {
                    ContentUnavailableView.search(text: model.searchQuery)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.background)
    }

    private var summary: String {
        let count = model.searchResults.count
        let matches = count == 1 ? "1 match" : "\(count) matches"
        return model.isSearching ? "\(matches) so far\u{2026}" : matches
    }
}

// MARK: - Password

private struct UnlockView: View {
    /// Tries the password; returns false if it was wrong.
    let tryPassword: (String) -> Bool

    @State private var password = ""
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc")
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkMuted)
            Text("This PDF Is Password-Protected")
                .font(Theme.display(20))
                .foregroundStyle(Theme.ink)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(unlock)
            if didFail {
                Text("That password didn\u{2019}t work. Try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            PrimaryButton(title: "Unlock", action: unlock)
                .disabled(password.isEmpty)
            Text("Highlights in password-protected PDFs are kept in Sheaf\u{2019}s library, not written into the file.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        if !tryPassword(password) {
            didFail = true
            password = ""
        }
    }
}
