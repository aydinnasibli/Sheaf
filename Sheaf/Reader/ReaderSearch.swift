import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The find bar that drops down over the page.
struct FindBar: View {
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

struct SearchResultsPanel: View {
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
