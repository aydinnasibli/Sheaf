import SwiftUI

/// A side panel shown over the content because there isn't room for it
/// beside the content (a narrow window, half a laptop screen). The content
/// behind is dimmed; clicking it, or Esc, puts the panel away.
struct PanelOverlay<Panel: View>: View {
    let edge: HorizontalEdge
    let dismiss: () -> Void
    @ViewBuilder var panel: Panel

    var body: some View {
        ZStack(alignment: edge == .leading ? .leading : .trailing) {
            Theme.scrim
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .accessibilityElement()
                .accessibilityLabel("Close panel")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { dismiss() }
            HStack(spacing: 0) {
                if edge == .trailing { Hairline(axis: .vertical) }
                panel
                if edge == .leading { Hairline(axis: .vertical) }
            }
            .frame(maxHeight: .infinity)
            // One shadow for the whole panel, not one per card inside it.
            .compositingGroup()
            .shadow(color: .black.opacity(0.16), radius: 18, x: edge == .leading ? 4 : -4)
            .onExitCommand(perform: dismiss)
        }
    }
}

extension View {
    /// Shows `panel` over this view while `isPresented`, sliding in from `edge`.
    func panelOverlay<Panel: View>(
        isPresented: Bool,
        edge: HorizontalEdge,
        dismiss: @escaping () -> Void,
        @ViewBuilder panel: @escaping () -> Panel
    ) -> some View {
        modifier(PanelOverlayModifier(isPresented: isPresented, edge: edge, dismiss: dismiss, panel: panel))
    }
}

private struct PanelOverlayModifier<Panel: View>: ViewModifier {
    let isPresented: Bool
    let edge: HorizontalEdge
    let dismiss: () -> Void
    let panel: () -> Panel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                if isPresented {
                    PanelOverlay(edge: edge, dismiss: dismiss, panel: panel)
                        .transition(reduceMotion ? .opacity : .move(edge: edge == .leading ? .leading : .trailing).combined(with: .opacity))
                }
            }
            .animation(Theme.motion, value: isPresented)
        }
    }
}
