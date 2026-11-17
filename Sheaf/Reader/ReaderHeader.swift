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

struct PagePill: View {
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

struct ZoomPill: View {
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
