import SwiftUI

extension ToolbarContent {
    /// Removes the glass capsule macOS 26 draws behind toolbar items, so the
    /// header matches Sheaf's own design. No effect on earlier macOS versions.
    @ToolbarContentBuilder
    func plainBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension View {
    /// The Sheaf header: background color and no title text in the toolbar.
    /// The window title is still set, so tabs and the Window menu show it.
    func sheafHeader() -> some View {
        toolbar(removing: .title)
            .toolbarBackground(Theme.background, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}
