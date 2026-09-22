import SwiftUI

/// Opacity of the theme tint laid over the window's behind-window vibrancy in the
/// sidebars: high enough that the (dark) theme color dominates for a darker
/// sidebar, while a little of the frosted desktop still reads through.
private let sidebarTintOpacity: Double = 0.7

/// A collapsible side column's backdrop — a translucent theme tint over the
/// window vibrancy, so it reads as themed chrome while the frosted desktop still
/// shows through. Content is overlaid by the caller (`SidebarThemes`,
/// `SidebarInspector`). Used for both the left and right columns.
struct SidebarTint: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.reduceTransparencyOverride) private var reduceTransparencyOverride

    var body: some View {
        theme.background.opacity(GlassA11y.sidebarOpacity(
            sidebarTintOpacity,
            reduceTransparency: GlassA11y.effective(system: reduceTransparency,
                                                    override: reduceTransparencyOverride)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-height activation strip used when a sidebar is closed. It is visually
/// absent at rest, then washes the complete window edge with a quiet shadow on
/// hover so any vertical position can restore the panel.
struct SidebarEdgeActivator: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let tooltip: String
    let edge: HorizontalEdge
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: edge == .leading ? .leading : .trailing) {
                edgeGlow
                    .opacity(hovering ? 1 : 0)

                Rectangle()
                    .fill(theme.accent.opacity(hovering ? 0.34 : 0.10))
                    .frame(width: Layout.hairline)

                SidebarEdgeDirectionIndicator(
                    systemImage: edge == .leading ? "chevron.right" : "chevron.left"
                )
                .opacity(hovering ? 1 : 0)
            }
            .frame(width: Layout.resizeHandleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(tooltip)
        .accessibilityLabel(tooltip)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }

    private var edgeGlow: some View {
        ZStack {
            Rectangle()
                .fill(theme.panel.opacity(0.16))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: edge == .leading
                            ? [theme.accent.opacity(0.12), theme.panel.opacity(0.08), .clear]
                            : [.clear, theme.panel.opacity(0.08), theme.accent.opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .shadow(color: .black.opacity(0.08), radius: 8)
    }
}

private struct SidebarEdgeDirectionIndicator: View {
    @Environment(ThemeStore.self) private var theme
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(theme.accent)
            .frame(width: Layout.resizeHandleWidth, height: 36)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

/// Small uppercase-ish section label pinned at the top of a sidebar.
private struct SidebarHeader: View {
    @Environment(ThemeStore.self) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(Typography.footnote)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }
}

/// Left sidebar content: a compact theme quick-switch list (same swatch data as
/// the settings theme grid). A plain VStack, not ScrollableContent: the rows are
/// few enough to fit the shortest window, and ScrollView content doesn't render
/// in the offscreen `--snapshot` path (see UIState's LGD_OPEN_SETTINGS note).
struct SidebarThemes: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarHeader(title: "Themes")
            ForEach(ThemeSwatch.all) { swatch in
                row(swatch)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ swatch: ThemeSwatch) -> some View {
        let selected = theme.id == swatch.themeID
        return Button {
            theme.id = swatch.themeID
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(swatch.pill)
                    .overlay(Circle().stroke(swatch.pillBorder, lineWidth: Layout.hairline))
                    .frame(width: 12, height: 12)
                Text(swatch.name)
                    .font(Typography.body)
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(Typography.iconTiny)
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(selected ? theme.selectionFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .accessibilityLabel(swatch.name)
        .accessibilityHint("Switches the theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Right sidebar content: a live readout of the appearance and glass-card state.
struct SidebarInspector: View {
    @Environment(ThemeStore.self) private var theme
    let model: TransparencyModel
    let ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "Inspector")
            row("Theme", value: ThemeSwatch.name(for: theme.id))
            row("Mode", value: ui.mode.rawValue)
            row("Card Opacity", value: "\(OpacityControl.card.percent(model.cardOpacity))%")
            row("Card Blur", value: "\(model.blurPercent)%")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ label: String, value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(Typography.body)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(value)
                    .font(Typography.control)
                    .foregroundStyle(theme.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle()
                .fill(theme.divider)
                .frame(height: Layout.hairline)
                .padding(.leading, 10)
        }
    }
}

/// A draggable column separator. It reads as the same hairline divider at rest,
/// but carries a wider invisible hit area; hovering (or dragging) thickens the
/// line, tints it with the theme accent, and shows the column-resize pointer.
/// Dragging adjusts the adjacent sidebar's width within `Layout.sidebar*Width`.
struct ResizableColumnDivider: View {
    @Environment(ThemeStore.self) private var theme
    @Bindable var ui: UIState

    /// Which side the resized sidebar sits on, so a rightward drag grows the left
    /// sidebar but shrinks the right one.
    let edge: HorizontalEdge
    var collapseAction: (() -> Void)? = nil

    @State private var hovering = false
    @State private var dragStartWidth: CGFloat?

    private var active: Bool { hovering || dragStartWidth != nil }

    private var width: Binding<CGFloat> {
        edge == .leading ? $ui.leftSidebarWidth : $ui.rightSidebarWidth
    }

    var body: some View {
        // A 1pt divider line pinned to the boundary edge, inside a wider transparent
        // grab zone. This is overlaid on the (opaque) sidebar tint rather than laid
        // out as its own column, so no window frost shows through and the layout
        // gains no extra width. Hovering/dragging recolors the line to the accent.
        ZStack(alignment: edge == .leading ? .trailing : .leading) {
            Color.clear

            Rectangle()
                .fill(theme.panel.opacity(active ? 0.16 : 0))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: edge == .leading
                            ? [.clear, theme.panel.opacity(0.08), theme.accent.opacity(0.12)]
                            : [theme.accent.opacity(0.12), theme.panel.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .opacity(active ? 1 : 0)
                .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 8)

            Rectangle()
                .fill(active ? theme.accent : theme.divider)
                .frame(width: Layout.hairline)

            SidebarEdgeDirectionIndicator(
                systemImage: edge == .leading ? "chevron.left" : "chevron.right"
            )
            .opacity(hovering ? 1 : 0)
        }
        .frame(width: Layout.resizeHandleWidth)
        .contentShape(Rectangle())
        .ignoresSafeArea(edges: .bottom)
        .pointerStyle(.columnResize)
        .help(collapseAction == nil ? "Drag to resize" : "Drag to resize · Click to collapse")
        .onHover { hovering = $0 }
        .gesture(
            // Measure in global space: the handle moves as the sidebar resizes,
            // so a local translation would feed back on itself and jitter.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? width.wrappedValue
                    if dragStartWidth == nil { dragStartWidth = start }
                    let delta = edge == .leading ? value.translation.width : -value.translation.width
                    width.wrappedValue = UIState.clampSidebar(start + delta)
                }
                .onEnded { value in
                    dragStartWidth = nil
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance < 3 {
                        collapseAction?()
                    }
                }
        )
        .animation(.easeInOut(duration: 0.12), value: active)
    }
}
