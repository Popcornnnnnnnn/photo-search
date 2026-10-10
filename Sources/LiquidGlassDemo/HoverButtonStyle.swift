import SwiftUI

/// Shared feedback for custom buttons. Native menus and form controls keep
/// their system styles; labels with their own layout can opt out of padding.
struct HoverButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 5
    var cornerRadius: CGFloat = Radius.control

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .modifier(HoverButtonSurface(
                pressed: configuration.isPressed,
                destructive: configuration.role == .destructive,
                cornerRadius: cornerRadius
            ))
    }
}

private struct HoverButtonSurface: ViewModifier {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    let pressed: Bool
    let destructive: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let active = isEnabled && (hovering || pressed)
        let tint = destructive ? theme.danger : theme.textPrimary
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if destructive {
                content.foregroundStyle(theme.danger)
            } else {
                content
            }
        }
            // Overlay also works on labels that already have an opaque surface.
            .overlay {
                shape.fill(tint.opacity(active ? (pressed ? 0.16 : 0.08) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(tint.opacity(active ? 0.18 : 0), lineWidth: Layout.hairline)
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
