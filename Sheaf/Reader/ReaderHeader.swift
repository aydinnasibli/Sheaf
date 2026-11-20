import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct TitleBlock: View {
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
struct PenPicker: View {
    let model: ReaderModel
    let compact: Bool
    /// In a narrow window even the picked pen goes without its name; its
    /// ring shows which one is picked.
    var showsPickedName = true

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(HighlightKind.allCases) { kind in
                let isActive = model.activePen == kind
                let showsName = !compact || (isActive && showsPickedName)
                Button { model.choosePen(kind) } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(kind.swatch)
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.12), lineWidth: 1))
                        if showsName {
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
                    .padding(.trailing, showsName ? 10 : 8)
                    .frame(height: 30)
                    .background(isActive ? Theme.penActive : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 2))
                }
                .buttonStyle(.sheaf(cornerRadius: 9))
                .help("\(kind.name) highlighter: select text, then press \(kind.rawValue). Option-drag to highlight an area.")
                .accessibilityLabel("\(kind.name) highlighter")
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
        // In compact mode the picked pen's name slides open instead of popping in.
        .animation(Theme.motion, value: model.activePen)
    }
}

/// Single / Two pages / Scroll. The picked layout shows its name.
struct LayoutSwitch: View {
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
                }
                .buttonStyle(.sheaf(isOn ? .primary : .fill, cornerRadius: 7))
                .help(layout.menuTitle)
                .accessibilityLabel(layout.menuTitle)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.control, lineWidth: 1))
        .fixedSize()
        .animation(Theme.motion, value: model.layout)
    }

    private func icon(for layout: ReaderModel.PageLayout) -> String {
        switch layout {
        case .single: "rectangle.portrait"
        case .twoPages: "rectangle.split.2x1"
        case .scroll: "rectangle.split.1x2"
        case .twoPageScroll: "rectangle.split.2x2"
        }
    }
}

struct PagePill: View {
    let model: ReaderModel

    var body: some View {
        let sideways = model.layout == .twoPages
        Pill {
            PillIconButton(label: "Previous page", systemImage: sideways ? "chevron.left" : "chevron.up", isEnabled: model.canGoToPreviousPage) {
                model.goToPreviousPage()
            }
            Button { model.isGoToPagePresented = true } label: {
                pageText
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .frame(height: 30)
            }
            .buttonStyle(.sheaf(cornerRadius: 7))
            .help("Go to page (\u{2325}\u{2318}G)")
            .accessibilityLabel(spokenPage)
            .accessibilityHint("Goes to a page")
            PillIconButton(label: "Next page", systemImage: sideways ? "chevron.right" : "chevron.down", isEnabled: model.canGoToNextPage) {
                model.goToNextPage()
            }
            PillIconButton(
                label: model.isCurrentPageBookmarked ? "Remove this page\u{2019}s bookmark (\u{2318}D)" : "Bookmark this page (\u{2318}D)",
                systemImage: model.isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                isEnabled: model.entry != nil
            ) {
                model.toggleBookmark()
            }
        }
    }

    /// "4 / 12", or with printed page numbers that differ from the count,
    /// "xii (14 of 244)", as Acrobat shows it.
    private var pageText: Text {
        let label = Text(model.pageLabel).fontWeight(.semibold).foregroundStyle(Theme.ink)
        guard model.pageLabel != model.pagePosition else {
            return label + Text(" / \(model.pageCount)").foregroundStyle(Theme.inkMuted)
        }
        return label + Text(" (\(model.pagePosition) of \(model.pageCount))").foregroundStyle(Theme.inkMuted)
    }

    private var spokenPage: String {
        guard model.pageLabel != model.pagePosition else { return "Page \(model.pageLabel) of \(model.pageCount)" }
        return "Page \(model.pageLabel), \(model.pagePosition) of \(model.pageCount)"
    }
}

/// Zoom out, a menu of page sizes and page options, and zoom in.
struct ZoomPill: View {
    @Bindable var model: ReaderModel
    @AppStorage(ReaderModel.darkPagesKey) private var darkPages = false

    var body: some View {
        Pill {
            PillIconButton(label: "Zoom out (\u{2318}\u{2212})", systemImage: "minus", action: model.zoomOut)
            Menu {
                Toggle("Fit Page", isOn: Binding(get: { model.zoomMode == .fitPage }, set: { _ in model.zoomToFit() }))
                Toggle("Fit Width", isOn: Binding(get: { model.zoomMode == .fitWidth }, set: { _ in model.zoomToWidth() }))
                Button("Actual Size", action: model.zoomToActualSize)
                Divider()
                Toggle("Book Spreads (Cover on Its Own)", isOn: $model.showsBookSpreads)
                    .disabled(!model.layout.showsPairs)
                Toggle("Dark Pages in Dark Mode", isOn: $darkPages)
            } label: {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 44)
                    .padding(.horizontal, 6)
                    .frame(height: 30)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.sheaf(cornerRadius: 7))
            .fixedSize()
            .help("Page size and page options")
            PillIconButton(label: "Zoom in (\u{2318}+)", systemImage: "plus", action: model.zoomIn)
        }
    }

    private var label: String {
        switch model.zoomMode {
        case .fitPage: "Fit page"
        case .fitWidth: "Fit width"
        case .custom: "\(model.zoomPercent)%"
        }
    }
}
