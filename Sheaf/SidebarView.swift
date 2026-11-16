import SwiftUI

/// Page thumbnails or the table of contents, replaced by search results
/// while a search is active.
struct SidebarView: View {
    @Bindable var model: ReaderModel

    var body: some View {
        if model.isShowingSearchResults {
            SearchResultsList(model: model)
        } else {
            VStack(spacing: 0) {
                Picker("Show", selection: $model.sidebarMode) {
                    Text("Pages").tag(ReaderModel.SidebarMode.pages)
                    Text("Contents").tag(ReaderModel.SidebarMode.contents)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                switch model.sidebarMode {
                case .pages:
                    ThumbnailView(pdfView: model.pdfView)
                case .contents:
                    OutlineList(model: model)
                }
            }
        }
    }
}

private struct OutlineList: View {
    let model: ReaderModel
    @State private var selection: OutlineItem.ID?

    var body: some View {
        if model.outline.isEmpty {
            ContentUnavailableView(
                "No Table of Contents",
                systemImage: "list.bullet.indent",
                description: Text("This PDF doesn't include one.")
            )
        } else {
            List(model.outline, children: \.children, selection: $selection) { item in
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .lineLimit(2)
            }
            .onChange(of: selection) { _, id in
                if let id, let item = Self.find(id, in: model.outline) {
                    model.go(to: item)
                }
            }
        }
    }

    private static func find(_ id: OutlineItem.ID, in items: [OutlineItem]) -> OutlineItem? {
        for item in items {
            if item.id == id { return item }
            if let match = find(id, in: item.children ?? []) { return match }
        }
        return nil
    }
}

private struct SearchResultsList: View {
    let model: ReaderModel

    private var selection: Binding<SearchResult.ID?> {
        Binding(
            get: { model.selectedResultID },
            set: { id in if let id { model.selectResult(id: id) } }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(model.searchResults) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page \(result.pageLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(result.snippet)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(summary)
            }
        }
        .overlay {
            if model.searchResults.isEmpty {
                if model.isSearching {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: model.searchQuery)
                }
            }
        }
    }

    private var summary: String {
        let count = model.searchResults.count
        let matches = count == 1 ? "1 match" : "\(count) matches"
        return model.isSearching ? "\(matches) so far…" : matches
    }
}
