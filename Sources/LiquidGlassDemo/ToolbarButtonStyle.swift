import SwiftUI

/// One surface owns toolbar feedback; selection stays visible between hovers.
struct ToolbarButtonStyle: ButtonStyle {
    var isSelected = false
    var cornerRadius: CGFloat = Radius.control

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(ToolbarButtonSurface(isSelected: isSelected,
                                           pressed: configuration.isPressed,
                                           cornerRadius: cornerRadius))
    }
}

private struct ToolbarButtonSurface: ViewModifier {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let isSelected: Bool
    let pressed: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let highlighted = isEnabled && (hovering || pressed)
        content
            .background(shape.fill(isSelected ? theme.accent.opacity(0.10) : .clear))
            // Selected Fit/Fill labels have their own opaque pill. Feedback
            // must stay above that surface without intercepting clicks.
            .overlay {
                shape.fill(theme.textPrimary.opacity(highlighted ? (pressed ? 0.16 : 0.08) : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .pointerStyle(isEnabled ? .link : .default)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
    }
}

extension ToolbarContent {
    /// Custom toolbar controls already draw their own hover and selected states.
    @ToolbarContentBuilder
    func customToolbarSurface() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
