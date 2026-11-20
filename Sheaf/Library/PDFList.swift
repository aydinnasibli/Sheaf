import QuickLook
import SwiftUI

/// The library's list of PDFs. It's a native Mac list, so selecting works
/// as in Finder: ⌘- and ⇧-click, ⌘A, the arrow keys, and typing the first
/// letters of a title. Return or a double-click opens, Space shows Quick
/// Look, Delete removes (after asking), and the context menu acts on the
/// whole selection. Rows drag out as files, to Finder, Mail or a collection.
/// It draws Sheaf's own rows and selection rather than the stock look.
struct PDFList: View {
    let rows: [LibraryEntry]
    let collections: [PDFCollection]
    @Binding var sortColumn: LibraryColumn
    @Binding var sortAscending: Bool

    @Environment(Workspace.self) private var workspace
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(sortColumn: $sortColumn, ascending: $sortAscending)
                // The list sets its rows in by this much; the columns line up.
                .padding(.horizontal, 8)
            List(selection: Bindable(workspace).librarySelection) {
                ForEach(rows) { entry in
                    LibraryRow(
                        entry: entry,
                        isSelected: workspace.librarySelection.contains(entry.id),
                        isListFocused: isFocused
                    ) {
                        workspace.openPDFs([entry])
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    // Opaque, so the system's blue selection doesn't show
                    // through; the row draws Sheaf's own.
                    .listRowBackground(Theme.background)
                    .itemProvider { workspace.dragItem(for: entry) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, LibraryRow.height)
            .focused($isFocused)
            .focusEffectDisabled()
            .contextMenu(forSelectionType: UUID.self) { ids in
                // Right-clicking a row outside the selection acts on that row only.
                let entries = entries(ids)
                if !entries.isEmpty {
                    PDFMenuItems(entries: entries, collections: collections, workspace: workspace)
                }
            } primaryAction: { ids in
                workspace.openPDFs(entries(ids))
            }
            .onDeleteCommand { workspace.requestRemoval(of: selectedEntries) }
            .onKeyPress(.space) {
                if workspace.quickLookFile == nil && selectedEntries.isEmpty { return .ignored }
                workspace.toggleQuickLook(selectedEntries)
                return .handled
            }
            .quickLookPreview(Bindable(workspace).quickLookFile, in: workspace.quickLookFiles)
            .onChange(of: isFocused, initial: true) { workspace.isLibraryListFocused = isFocused }
            .onDisappear { workspace.isLibraryListFocused = false }
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            // PDFs hidden by the search or a filter don't stay selected
            // where the menus would act on them unseen.
            let shown = Set(ids)
            if !workspace.librarySelection.isSubset(of: shown) {
                workspace.librarySelection.formIntersection(shown)
            }
        }
    }

    /// The selected PDFs, in list order.
    private var selectedEntries: [LibraryEntry] {
        rows.filter { workspace.librarySelection.contains($0.id) }
    }

    private func entries(_ ids: Set<UUID>) -> [LibraryEntry] {
        rows.filter { ids.contains($0.id) }
    }
}
