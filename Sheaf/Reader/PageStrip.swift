import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The left strip: page thumbnails, or the table of contents when the PDF
/// has one.
struct PageStrip: View {
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
struct ContentsList: View {
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
struct ThumbnailList: View {
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

struct ThumbnailCell: View {
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
