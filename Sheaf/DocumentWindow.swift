import SwiftUI

/// The reader layout: sidebar, pages, toolbar and search.
struct DocumentWindow: View {
    @Bindable var model: ReaderModel

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var pageEntry = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 320)
        } detail: {
            PDFKitView(pdfView: model.pdfView)
        }
        .navigationSubtitle(pageSubtitle)
        .toolbar { toolbarContent }
        .searchable(text: $model.searchQuery, placement: .toolbar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onSubmit(of: .search) { model.selectNextResult() }
        .task(id: model.searchQuery) {
            // Wait for a pause in typing before searching.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            model.search()
        }
        .onChange(of: model.isShowingSearchResults) { _, isShowing in
            if isShowing { columnVisibility = .all }
        }
        .onChange(of: model.searchFocusRequest) {
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
        .focusedSceneValue(model)
        .task { model.restoreReadingPosition() }
        .onDisappear { model.close() }
    }

    private var pageSubtitle: String {
        model.pageCount == 0 ? "No pages" : "Page \(model.currentPageIndex + 1) of \(model.pageCount)"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            ControlGroup {
                Button("Previous Page", systemImage: "chevron.up", action: model.goToPreviousPage)
                    .disabled(!model.canGoToPreviousPage)
                Button("Next Page", systemImage: "chevron.down", action: model.goToNextPage)
                    .disabled(!model.canGoToNextPage)
            } label: {
                Label("Page", systemImage: "doc")
            }
            .help("Previous or next page")
        }
        ToolbarItem {
            ControlGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass", action: model.zoomOut)
                Button("Zoom In", systemImage: "plus.magnifyingglass", action: model.zoomIn)
            } label: {
                Label("Zoom", systemImage: "magnifyingglass")
            }
            .help("Zoom out or in")
        }
    }
}
