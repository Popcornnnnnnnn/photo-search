import AVKit
import SwiftUI

struct PhotoSidebar: View {
    @Environment(ThemeStore.self) private var theme
    let store: PhotoSearchStore
    let activity: PhotoIndexActivity
    @Bindable var ui: UIState
    let onRandomBrowse: () -> Void
    let onReview: () -> Void

    @State private var randomHovering = false
    @State private var settingsHovering = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 2) {
            Text("LIBRARY")
                .font(Typography.footnote)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 7)

            ForEach(PhotoSection.allCases) { section in
                PhotoSidebarRow(
                    section: section,
                    selected: store.section == section
                ) {
                    if store.isViewerPresented { store.closeViewer() }
                    store.section = section
                }
            }

            Spacer()

            Button(action: onRandomBrowse) {
                HStack(spacing: 9) {
                    Image(systemName: "shuffle")
                        .frame(width: 17)
                    Text("Browse randomly")
                    Spacer()
                }
                .font(Typography.body)
                .foregroundStyle(randomHovering ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(randomHovering ? theme.hoverFill : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Show a random photo")
            .onHover { randomHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: randomHovering)

            Button(action: onReview) {
                HStack(spacing: 9) {
                    Image(systemName: "checklist").frame(width: 17)
                    Text("Review photos")
                    Spacer()
                }
                .font(Typography.body)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(horizontalPadding: 0, verticalPadding: 0, cornerRadius: Radius.row))
            .pointerStyle(.link)
            .help("Review possible blank, blurred or accidental photos")

            Button {
                ui.showSettings = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 17)
                    Text("Settings…")
                    Spacer()
                    Text("⌘,")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary.opacity(0.72))
                }
                .font(Typography.body)
                .foregroundStyle(settingsHovering ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(settingsHovering ? theme.hoverFill : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { settingsHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: settingsHovering)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(activityTint)
                        .frame(width: 7, height: 7)
                    Text("\(store.stats.indexed.formatted()) of \(store.stats.total.formatted()) indexed")
                        .foregroundStyle(theme.textPrimary)
                }

                ProgressView(
                    value: Double(store.stats.indexed),
                    total: Double(max(1, store.stats.total))
                )
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(theme.accent)

                if let caption = activity.caption {
                    Text(caption)
                        .foregroundStyle(theme.textSecondary)
                }

                if store.stats.failed > 0 {
                    Label(
                        "\(store.stats.failed.formatted()) deferred · automatic retry",
                        systemImage: "arrow.clockwise.circle"
                    )
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .font(Typography.footnote)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.divider.opacity(0.75))
                    .frame(height: Layout.hairline)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, Layout.headerHeight)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var activityTint: Color {
        switch activity {
        case .indexing: .green
        case .paused, .completeWithErrors: .orange
        case .complete: .green
        case .idle, .waiting, .stale: theme.textSecondary.opacity(0.4)
        }
    }
}

private struct PhotoSidebarRow: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let section: PhotoSection
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .frame(width: 17)
                    .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                Text(section.title)
                    .font(Typography.body)
                    .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background { rowBackground }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(horizontalPadding: 0, verticalPadding: 0, cornerRadius: Radius.row))
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .fill(selected ? theme.selectionFill : (hovering ? theme.hoverFill : .clear))
    }
}

struct PhotoSearchBar: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: PhotoSearchStore
    let history: SearchHistoryStore
    let encoder: PhotoEncoderStore
    @Binding var thumbnailContentMode: ContentMode
    let onEmpty: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var clearHovering = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(focused ? theme.accent : theme.textSecondary)

                TextField("Search photos…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { store.submit(history: history, encoder: encoder) }

                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(clearHovering ? theme.textPrimary : theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .background(clearHovering ? theme.hoverFill : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                    .onHover { clearHovering = $0 }
                }

                Button {
                    store.submit(history: history, encoder: encoder)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(String(localized: "Search · Return", bundle: .module))
                .accessibilityLabel(String(localized: "Search", bundle: .module))

                Rectangle()
                    .fill(theme.divider.opacity(0.75))
                    .frame(width: Layout.hairline, height: 16)

                if store.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Searching photos")
                }
                Text(resultCountLabel)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary.opacity(0.82))
                    .fixedSize()
            }
            .padding(.horizontal, 17)
            .frame(height: 44)
            .modifier(SearchGlassSurface(active: focused, hovering: hovering))
            .overlay {
                Capsule()
                    .strokeBorder(
                        focused
                            ? theme.accent.opacity(0.58)
                            : theme.textPrimary.opacity(hovering ? 0.13 : 0.07),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: focused ? theme.accent.opacity(0.12) : .black.opacity(hovering ? 0.08 : 0.045),
                radius: focused ? 13 : (hovering ? 8 : 5),
                y: 2
            )
            .contentShape(Capsule())
            .onTapGesture { focused = true }
            .onHover { hovering = $0 }

            // Sits beside the field rather than on its own row below, so the
            // library grid starts higher and there is no second control strip.
            PhotoDateFilterButton(selection: $store.timeFilter)

            PhotoImageSizingPicker(selection: $thumbnailContentMode)
        }
        .frame(maxWidth: 660)
        .onChange(of: store.query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onEmpty()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .animation(.easeOut(duration: 0.16), value: focused)
    }

    private var resultCountLabel: String {
        if store.submittedQuery.isEmpty {
            return store.section.countDescription(store.resultCount)
        }
        return "\(store.resultCount.formatted()) results"
    }
}

private struct PhotoImageSizingPicker: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: ContentMode
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.fit, title: "Fit", icon: "arrow.down.right.and.arrow.up.left",
                       help: "Show the entire image")
            modeButton(.fill, title: "Fill", icon: "arrow.up.left.and.arrow.down.right",
                       help: "Fill each card, cropping the edges")
        }
        .padding(3)
        .background(theme.selectionFill, in: RoundedRectangle(cornerRadius: 10))
        .themedBorder(10)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image sizing")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
    }

    private func modeButton(_ mode: ContentMode, title: String, icon: String, help: String) -> some View {
        Button {
            selection = mode
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .font(Typography.control)
                .foregroundStyle(selection == mode ? theme.accent : theme.textSecondary)
                .frame(width: 74, height: 30)
                .background {
                    if selection == mode {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(theme.background)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(HoverButtonStyle(horizontalPadding: 0, verticalPadding: 0, cornerRadius: 7))
        .pointerStyle(.link)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }
}

struct PhotoLandingSearchView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var query: String
    let encoder: PhotoEncoderStore
    let indexedCount: Int
    let onSubmit: () -> Void
    let onBrowse: () -> Void
    let onRandomBrowse: () -> Void
    let onSettings: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var submitHovering = false
    @State private var pointerPosition = UnitPoint.center
    @State private var fieldSize = CGSize(width: 720, height: 64)
    @State private var rainbowPhase = 0.0

    private let searchBlue = Color(hex: 0x2463EB)

    private var canSubmit: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 18) {
            searchField
                .frame(maxWidth: 720)

            EncoderLoadNotice(store: encoder)
                .frame(maxWidth: 720)

            entries
        }
            .frame(maxWidth: 720)
            .overlay(alignment: .top) {
                branding
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 32)
                    .alignmentGuide(.top) { $0[.bottom] }
            }
    }

    /// Ways into the library that don't require typing a query first.
    private var entries: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                LandingEntryButton(
                    title: "Browse library",
                    systemImage: "photo.on.rectangle.angled",
                    action: onBrowse
                )
                LandingEntryButton(
                    title: "Browse randomly",
                    systemImage: "shuffle",
                    action: onRandomBrowse
                )
                LandingEntryButton(
                    title: "Settings",
                    systemImage: "slider.horizontal.3",
                    action: onSettings
                )
            }

            // Appears once the index count lands; kept out of the button label so
            // the buttons never change width while the library loads.
            if indexedCount > 0 {
                Text("\(indexedCount.formatted()) photos indexed")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary.opacity(0.85))
            }
        }
    }

    private var branding: some View {
        VStack(spacing: 0) {
            AppIconView()
                .scaleEffect(96 / 1024)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .padding(.bottom, 12)

            VStack(spacing: 8) {
                Text("Photo Search")
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(theme.textPrimary)

                Text("Find a photo from what you remember.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(searchBlue)
                .accessibilityHidden(true)

            TextField("", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .foregroundStyle(theme.textPrimary)
                .focused($focused)
                .onSubmit(submit)
                .overlay(alignment: .leading) {
                    // Hidden while focused: during IME composition the field is
                    // still empty, so an overlay placeholder would draw on top of
                    // the marked text the input method is composing.
                    if query.isEmpty && !focused {
                        Text("Describe a photo, a moment, or text…")
                            .font(.system(size: 17))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Search photos")
                .accessibilityHint("Describe a photo, a moment, or text")

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSubmit ? Color.white : theme.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(
                        canSubmit
                            ? searchBlue.opacity(submitHovering ? 0.85 : 1)
                            : theme.textSecondary.opacity(0.08),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(!canSubmit)
            .help("Search · Return")
            .accessibilityLabel("Search")
            .onHover { submitHovering = $0 }
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .frame(height: 64)
        .modifier(SearchGlassSurface(active: focused, hovering: hovering))
        .background {
            Capsule()
                .stroke(rainbowGradient, lineWidth: 7)
                .blur(radius: 12)
                .opacity(focused ? 0.20 : (hovering ? 0.14 : 0.06))
                .padding(-2)
        }
        .overlay {
            ZStack {
                Capsule()
                    .strokeBorder(
                        theme.textPrimary.opacity(focused ? 0.05 : 0.12),
                        lineWidth: 1
                    )

                Capsule()
                    .strokeBorder(
                        rainbowGradient,
                        lineWidth: focused ? 1.7 : 1.2
                    )
                    .opacity(focused ? 0.82 : (hovering ? 0.65 : 0.32))

                Capsule()
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.65), .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75
                    )
                    .padding(1.5)

                Capsule()
                    .strokeBorder(
                        RadialGradient(
                            colors: [.white.opacity(0.95), .white.opacity(0.25), .clear],
                            center: pointerPosition,
                            startRadius: 0,
                            endRadius: 190
                        ),
                        lineWidth: 2
                    )
                    .opacity(hovering && !reduceMotion ? 0.8 : 0)
            }
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.045), radius: 16, y: 7)
        .shadow(
            color: searchBlue.opacity(focused ? 0.07 : 0),
            radius: 12,
            y: 4
        )
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { fieldSize = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hovering = true
                guard !reduceMotion else { return }
                let x = min(max(location.x / max(1, fieldSize.width), 0), 1)
                let y = min(max(location.y / max(1, fieldSize.height), 0), 1)
                pointerPosition = UnitPoint(x: x, y: y)
            case .ended:
                hovering = false
                pointerPosition = .center
            }
        }
        .task(id: reduceMotion) {
            focused = true
            rainbowPhase = 0
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) {
                rainbowPhase = 360
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pointerPosition)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: focused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: canSubmit)
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit()
    }

    private var rainbowGradient: AngularGradient {
        let angle = rainbowPhase + (pointerPosition.x - 0.5) * 36
        return AngularGradient(
            colors: [
                Color(hex: 0x4B83F5), Color(hex: 0x51CDBF),
                Color(hex: 0xF3C565), Color(hex: 0xF58D9B),
                Color(hex: 0xB08AE8), Color(hex: 0x76C5F4),
                Color(hex: 0x4B83F5)
            ],
            center: .center,
            startAngle: .degrees(angle),
            endAngle: .degrees(angle + 360)
        )
    }
}

/// Shown while the visual-search encoder loads its model into memory.
///
/// The model is a 2B vision transformer held by a separate process, so the first
/// search after an offload has to wait for it. The bar tracks the real load
/// stages rather than animating on its own.
struct EncoderLoadNotice: View {
    @Environment(ThemeStore.self) private var theme
    let store: PhotoEncoderStore

    var body: some View {
        if store.isLoading {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "eye.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.accent)
                    Text("Preparing visual search")
                        .font(Typography.control)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("\(Int((store.loadProgress * 100).rounded()))%")
                        .font(Typography.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
                ProgressView(value: store.loadProgress)
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                Text(store.loadStage)
                    .font(Typography.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(12)
            .background(theme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.content))
            .themedBorder(Radius.content)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preparing visual search")
            .accessibilityValue(store.loadStage)
        }
    }
}

/// Secondary action on the landing screen: quiet capsule, icon plus a plain
/// command name, so the entries stay visible without competing with the field.
private struct LandingEntryButton: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(theme.textPrimary.opacity(hovering ? 0.10 : 0.06)))
            .overlay { Capsule().strokeBorder(theme.textPrimary.opacity(0.08), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}

private struct SearchGlassSurface: ViewModifier {
    @Environment(ThemeStore.self) private var theme
    let active: Bool
    let hovering: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(
                    theme.panel.opacity(active ? 0.34 : (hovering ? 0.26 : 0.20)),
                    in: Capsule()
                )
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(
                    theme.panel.opacity(active ? 0.55 : (hovering ? 0.45 : 0.36)),
                    in: Capsule()
                )
        }
    }
}

private struct PhotoGlassSurface: ViewModifier {
    @Environment(ThemeStore.self) private var theme
    let radius: CGFloat
    let tintOpacity: Double
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if interactive {
                content
                    .background(
                        theme.panel.opacity(tintOpacity),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                    )
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: radius))
            } else {
                content
                    .background(
                        theme.panel.opacity(tintOpacity),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                    )
                    .glassEffect(.clear, in: .rect(cornerRadius: radius))
            }
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .background(
                    theme.panel.opacity(max(0.26, tintOpacity)),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
        }
    }
}

private extension View {
    func photoGlassSurface(radius: CGFloat,
                           tintOpacity: Double,
                           interactive: Bool = false) -> some View {
        modifier(PhotoGlassSurface(
            radius: radius,
            tintOpacity: tintOpacity,
            interactive: interactive
        ))
    }
}

struct PhotoGrid: View {
    @Environment(ThemeStore.self) private var theme
    let store: PhotoSearchStore
    let encoder: PhotoEncoderStore
    let thumbnailContentMode: ContentMode
    var scrollToPhotoID: String? = nil
    var scrollToken = 0
    let onSelect: (IndexedPhoto) -> Void

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 10)]

    var body: some View {
        @Bindable var store = store
        ScrollableContent(scrollToID: scrollToPhotoID, scrollToken: scrollToken) {
            if let details = store.searchNotice, !store.photos.isEmpty {
                SearchCoverageNotice(title: store.searchNoticeTitle, details: details)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(store.photos) { photo in
                    PhotoCard(
                        photo: photo,
                        selected: store.selectedID == photo.id,
                        contentMode: thumbnailContentMode
                    )
                        .id(photo.id)
                        .onTapGesture(count: 2) { store.openViewer(for: photo) }
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                onSelect(photo)
                            }
                        )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 20)

            if store.hasMore {
                HStack {
                    Spacer()
                    if store.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(String(localized: "Load more", bundle: .module)) {
                            Task { await store.loadMore() }
                        }
                        .buttonStyle(HoverButtonStyle())
                    }
                    Spacer()
                }
                .padding(.bottom, 20)
            }
        }
        .overlay {
            if store.isLoading && store.photos.isEmpty {
                if encoder.isLoading {
                    EncoderLoadNotice(store: encoder)
                        .frame(maxWidth: 420)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    ProgressView("Loading photo index…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            } else if let error = store.errorMessage {
                ContentUnavailableView("Unable to open the photo index",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if store.photos.isEmpty {
                if let details = store.searchNotice {
                    ContentUnavailableView {
                        Label(store.searchNoticeTitle ?? "No matching photos", systemImage: "magnifyingglass")
                    } description: {
                        Text(details)
                    }
                } else {
                    ContentUnavailableView.search(text: store.submittedQuery)
                }
            }
        }
    }
}

struct PhotoInspector: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: PhotoSearchStore
    var showsThumbnail = true

    @State private var thumbnailHovering = false
    @State private var revealsSensitiveText = false

    var body: some View {
        if let photo = store.selectedPhoto {
            ScrollableContent {
                VStack(alignment: .leading, spacing: 16) {
                    if showsThumbnail {
                        PhotoThumbnailView(path: photo.thumbnailPath, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .background(theme.panel.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        thumbnailHovering ? theme.accent.opacity(0.55) : theme.border.opacity(0.55),
                                        lineWidth: thumbnailHovering ? 1 : Layout.hairline
                                    )
                            }
                            .scaleEffect(thumbnailHovering && !reduceMotion ? 1.008 : 1)
                            .shadow(color: .black.opacity(thumbnailHovering ? 0.14 : 0.05),
                                    radius: thumbnailHovering ? 10 : 4,
                                    y: thumbnailHovering ? 4 : 2)
                            .onHover { thumbnailHovering = $0 }
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.15),
                                       value: thumbnailHovering)
                    }

                    if containsSensitiveText(in: photo) {
                        HStack(spacing: 7) {
                            Label(
                                revealsSensitiveText ? "Sensitive text visible" : "Sensitive text hidden",
                                systemImage: revealsSensitiveText ? "eye" : "eye.slash"
                            )
                            Spacer(minLength: 8)
                            Button(revealsSensitiveText ? "Hide" : "Reveal") {
                                revealsSensitiveText.toggle()
                            }
                            .buttonStyle(HoverButtonStyle(horizontalPadding: 6, verticalPadding: 3))
                            .foregroundStyle(theme.accent)
                            .pointerStyle(.link)
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                    }

                    inspectorSection("AI SUMMARY") {
                        Text(display(photo.annotation?.shortCaption ?? photo.shortCaption))
                            .font(.body.weight(.medium))
                    }

                    if let annotation = photo.annotation {
                        inspectorSection("ANALYSIS") {
                            StructuredDescriptionView(
                                annotation: annotation,
                                revealsSensitiveText: revealsSensitiveText
                            )
                        }
                    }

                    let tags = uniqueTags((photo.annotation?.topics ?? []) + (photo.annotation?.entities ?? []))
                    if !tags.isEmpty {
                        inspectorSection("TAGS") {
                            FlowTags(tags: Array(tags.prefix(16)).map(display))
                        }
                    }

                    inspectorSection("DETAILS") {
                        metadataRow("Type", photo.displayAssetType)
                        if let duration = photo.displayDuration { metadataRow(String(localized: "Duration", bundle: .module), duration) }
                        if let model = photo.model { metadataRow("Model", model) }
                        if let capturedAt = photo.displayCapturedAt { metadataRow("Captured", capturedAt) }
                        if let width = photo.width, let height = photo.height {
                            metadataRow("Size", "\(width) × \(height)")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, Layout.headerHeight + 14)
                .padding(.bottom, 14)
            }
            .onChange(of: store.selectedID) { _, _ in
                revealsSensitiveText = false
            }
        } else {
            ContentUnavailableView("Select a photo", systemImage: "photo")
        }
    }

    private func inspectorSection<Content: View>(_ title: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typography.footnote)
                .foregroundStyle(theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func uniqueTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private func display(_ text: String) -> String {
        revealsSensitiveText ? text : SensitiveText.redact(text)
    }

    private func containsSensitiveText(in photo: IndexedPhoto) -> Bool {
        var values = [photo.shortCaption]
        if let annotation = photo.annotation {
            values += [
                annotation.shortCaption,
                annotation.detailedDescription,
                annotation.scene
            ].compactMap { $0 }
            values += annotation.observedFacts ?? []
            values += annotation.inferences ?? []
            values += annotation.uncertainties ?? []
            values += annotation.entities ?? []
            values += annotation.topics ?? []
        }
        return values.contains(where: SensitiveText.containsSensitiveContent)
    }
}

private struct StructuredDescriptionView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let annotation: PhotoAnnotation
    let revealsSensitiveText: Bool

    @State private var showsFullDescription = false
    @State private var hoveredBlock: String?
    @State private var fullDescriptionHovering = false

    private var facts: [String] { Array((annotation.observedFacts ?? []).prefix(6)) }
    private var inferences: [String] { Array((annotation.inferences ?? []).prefix(3)) }
    private var uncertainties: [String] { Array((annotation.uncertainties ?? []).prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let scene = annotation.scene, !scene.isEmpty {
                descriptionBlock(title: "Scene", systemImage: "viewfinder") {
                    Text(display(scene))
                }
            }

            if !facts.isEmpty {
                descriptionBlock(title: "Visible details", systemImage: "eye") {
                    bulletList(facts.map(display))
                }
            }

            if let actions = annotation.actions, !actions.isEmpty {
                descriptionBlock(title: "Actions", systemImage: "figure.walk.motion") {
                    FlowTags(tags: Array(actions.prefix(8)).map(display))
                }
            }

            if !inferences.isEmpty {
                descriptionBlock(title: "Interpretation", systemImage: "lightbulb") {
                    bulletList(inferences.map(display))
                }
            }

            if !uncertainties.isEmpty {
                descriptionBlock(title: "Uncertain", systemImage: "questionmark.circle") {
                    bulletList(uncertainties.map(display))
                }
            }

            if let full = annotation.detailedDescription, !full.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            showsFullDescription.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showsFullDescription ? 90 : 0))
                                .accessibilityHidden(true)
                            Label("Full model description", systemImage: "text.alignleft")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsFullDescription ? "Expanded" : "Collapsed")

                    if showsFullDescription {
                        Text(display(full))
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }
                .photoGlassSurface(
                    radius: 9,
                    tintOpacity: fullDescriptionHovering ? 0.30 : 0.20,
                    interactive: true
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            fullDescriptionHovering ? theme.accent.opacity(0.48) : theme.border.opacity(0.45),
                            lineWidth: Layout.hairline
                        )
                }
                .scaleEffect(fullDescriptionHovering && !reduceMotion ? 1.008 : 1)
                .onHover { fullDescriptionHovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15),
                           value: fullDescriptionHovering)
            }
        }
    }

    private func descriptionBlock<Content: View>(title: String,
                                                  systemImage: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            content()
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .photoGlassSurface(
            radius: 10,
            tintOpacity: hoveredBlock == title ? 0.32 : 0.22,
            interactive: true
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    hoveredBlock == title ? theme.accent.opacity(0.48) : theme.border.opacity(0.7),
                    lineWidth: Layout.hairline
                )
        }
        .scaleEffect(hoveredBlock == title && !reduceMotion ? 1.008 : 1)
        .shadow(color: .black.opacity(hoveredBlock == title ? 0.12 : 0.03),
                radius: hoveredBlock == title ? 8 : 3,
                y: hoveredBlock == title ? 3 : 1)
        .onHover { hovering in hoveredBlock = hovering ? title : nil }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveredBlock)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(theme.accent.opacity(0.8))
                        .frame(width: 4, height: 4)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func display(_ text: String) -> String {
        revealsSensitiveText ? text : SensitiveText.redact(text)
    }
}

struct PhotoOneUpView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(ErrorStore.self) private var errors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: PhotoSearchStore
    @Binding var infoVisible: Bool
    var showsToolbar = true
    var sidebarVisible = false
    var onToggleSidebar: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var zoom: CGFloat = 1
    @State private var rotationQuarterTurns = 0
    @State private var magnificationBase: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var dragBase: CGSize?
    @State private var didCopyImage = false
    @State private var copyFeedbackGeneration = 0
    @State private var pagingOffset: CGFloat = 0
    @State private var pagingSettling = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    theme.background.opacity(0.96)

                    if let previous = store.previousPhoto {
                        viewerPhoto(previous, canvasSize: proxy.size)
                            .offset(x: pagingOffset - proxy.size.width)
                    }

                    if let photo = store.selectedPhoto {
                        viewerPhoto(photo, canvasSize: proxy.size, selected: true)
                            .offset(x: pagingOffset)
                        .onTapGesture(count: 2) {
                            guard !photo.isVideo else { return }
                            withAnimation(.easeInOut(duration: 0.18)) {
                                setZoom(zoom > 1 ? 1 : 2, canvasSize: proxy.size)
                            }
                        }
                    }

                    if let next = store.nextPhoto {
                        viewerPhoto(next, canvasSize: proxy.size)
                            .offset(x: pagingOffset + proxy.size.width)
                    }

                    TrackpadPagingObserver(
                        onChanged: { translation in
                            updatePaging(translation, canvasWidth: proxy.size.width)
                        },
                        onEnded: {
                            finishPaging(canvasWidth: proxy.size.width)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .gesture(magnificationGesture(canvasSize: proxy.size))
                .simultaneousGesture(panGesture(canvasSize: proxy.size))
            }
            .clipped()
            .contentShape(Rectangle())
        }
        .toolbar { if showsToolbar { viewerToolbar } }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: store.selectedID) { _, _ in
            resetTransform()
            copyFeedbackGeneration += 1
            didCopyImage = false
            if !pagingSettling { pagingOffset = 0 }
        }
        .onKeyPress(.leftArrow) {
            store.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            store.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            store.closeViewer()
            return .handled
        }
    }

    @ToolbarContentBuilder
    private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 4) {
                ViewerBackButton { store.closeViewer() }
                    .keyboardShortcut(.escape, modifiers: [])
                if let onToggleSidebar {
                    ViewerToolbarButton(systemImage: "sidebar.left",
                                        tooltip: sidebarVisible ? "Hide sidebar" : "Show sidebar",
                                        isActive: sidebarVisible, action: onToggleSidebar)
                }
            }
        }
        ToolbarItem(placement: .principal) {
            if let photo = store.selectedPhoto {
                VStack(spacing: 1) {
                    Text(photo.displayCapturedAt ?? photo.filename)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    if let position = store.selectedPositionLabel {
                        Text(position).font(.caption2).foregroundStyle(theme.textSecondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: 320)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if store.selectedPhoto?.isVideo != true {
            ViewerToolbarButton(systemImage: "rotate.right", tooltip: "Rotate Clockwise") {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    rotationQuarterTurns += 1
                    panOffset = .zero
                }
            }
            ViewerToolbarButton(systemImage: didCopyImage ? "checkmark" : "doc.on.doc",
                                tooltip: didCopyImage ? "Copied" : "Copy Image") {
                copySelectedImage()
            }
            }
            ViewerToolbarButton(systemImage: "sidebar.right",
                                tooltip: infoVisible ? "Hide info" : "Show info",
                                isActive: infoVisible) {
                infoVisible.toggle()
            }
        }
    }

    private func copySelectedImage() {
        guard let photo = store.selectedPhoto else { return }
        guard PhotoClipboard.copy(photo) else {
            errors.present(
                title: "Unable to Copy Image",
                message: "The original image and its local preview could not be read."
            )
            return
        }

        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        didCopyImage = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard generation == copyFeedbackGeneration else { return }
            didCopyImage = false
        }
    }

    @ViewBuilder
    private func viewerPhoto(_ photo: IndexedPhoto,
                             canvasSize: CGSize,
                             selected: Bool = false) -> some View {
        let turns = selected ? rotationQuarterTurns : 0
        let availableWidth = max(0, canvasSize.width - 48)
        let availableHeight = max(0, canvasSize.height - 48)
        if selected && photo.isVideo {
            PhotoVideoView(photo: photo)
                .id(photo.id)
                .frame(width: canvasSize.width, height: canvasSize.height)
        } else {
        PhotoThumbnailView(
            path: !photo.isVideo && FileManager.default.fileExists(atPath: photo.filePath)
                ? photo.filePath
                : photo.thumbnailPath,
            contentMode: .fit,
            maxPixelSize: 3200,
            rotationDegrees: Double(turns * 90),
            onDisplayed: selected ? { PhotoViewHistory.record(photo.id) } : nil
        )
        .id(photo.id)
        .frame(width: availableWidth, height: availableHeight)
        .scaleEffect(selected ? zoom : 1)
        .offset(selected ? panOffset : .zero)
        .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    private func updatePaging(_ translation: CGFloat, canvasWidth: CGFloat) {
        guard !pagingSettling, zoom <= 1.001 else { return }

        let bounded = min(canvasWidth, max(-canvasWidth, translation))
        let hasDestination = bounded < 0 ? store.canSelectNext : store.canSelectPrevious
        pagingOffset = hasDestination ? bounded : bounded * 0.18
    }

    private func finishPaging(canvasWidth: CGFloat) {
        guard !pagingSettling, zoom <= 1.001 else { return }

        let threshold = min(120, canvasWidth * 0.18)
        let movesNext = pagingOffset <= -threshold && store.canSelectNext
        let movesPrevious = pagingOffset >= threshold && store.canSelectPrevious
        guard movesNext || movesPrevious else {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.88)) {
                pagingOffset = 0
            }
            return
        }

        pagingSettling = true
        let target = movesNext ? -canvasWidth : canvasWidth
        let selectionOffset = movesNext ? 1 : -1
        withAnimation(
            .interactiveSpring(response: 0.28, dampingFraction: 0.90),
            completionCriteria: .logicallyComplete
        ) {
            pagingOffset = target
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                store.moveSelection(by: selectionOffset)
                pagingOffset = 0
                pagingSettling = false
            }
        }
    }

    private func magnificationGesture(canvasSize: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if magnificationBase == nil { magnificationBase = zoom }
                zoom = min(3, max(1, (magnificationBase ?? zoom) * value.magnification))
                panOffset = clamped(panOffset, canvasSize: canvasSize)
            }
            .onEnded { _ in
                magnificationBase = nil
                if zoom <= 1.001 { resetTransform() }
            }
    }

    private func panGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard zoom > 1 else { return }
                if dragBase == nil { dragBase = panOffset }
                let base = dragBase ?? panOffset
                panOffset = clamped(
                    CGSize(width: base.width + value.translation.width,
                           height: base.height + value.translation.height),
                    canvasSize: canvasSize
                )
            }
            .onEnded { _ in dragBase = nil }
    }

    private func setZoom(_ value: CGFloat, canvasSize: CGSize) {
        zoom = min(3, max(1, value))
        panOffset = zoom == 1 ? .zero : clamped(panOffset, canvasSize: canvasSize)
    }

    private func resetTransform() {
        zoom = 1
        rotationQuarterTurns = 0
        magnificationBase = nil
        panOffset = .zero
        dragBase = nil
    }

    private func clamped(_ offset: CGSize, canvasSize: CGSize) -> CGSize {
        guard zoom > 1 else { return .zero }
        let horizontalLimit = max(0, canvasSize.width * (zoom - 1) / 2)
        let verticalLimit = max(0, canvasSize.height * (zoom - 1) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }
}

struct ViewerBackButton: View {
    var tooltip = "Back to photos (Esc)"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(HoverButtonStyle(horizontalPadding: 0, verticalPadding: 0))
        .accessibilityLabel(tooltip)
        .help(tooltip)
    }
}

struct ViewerToolbarButton: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let systemImage: String
    let tooltip: String
    var isActive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? theme.accent : (hovering && isEnabled ? theme.textPrimary : theme.textSecondary))
                .frame(width: 28, height: 26)
                .background(hovering && isEnabled ? theme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel(String(localized: String.LocalizationValue(tooltip), bundle: .module))
        .help(String(localized: String.LocalizationValue(tooltip), bundle: .module))
        .onHover { hovering = $0 }
    }
}

private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        TagFlowLayout(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                HoverTag(text: tag)
            }
        }
    }
}

private struct HoverTag: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String

    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(theme.accent.opacity(hovering ? 0.22 : 0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(theme.accent.opacity(hovering ? 0.45 : 0.12),
                                  lineWidth: Layout.hairline)
            }
            .foregroundStyle(theme.textPrimary)
            .scaleEffect(hovering && !reduceMotion ? 1.045 : 1)
            .offset(y: hovering && !reduceMotion ? -1 : 0)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}

private struct TagFlowLayout: SwiftUI.Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize,
                     subviews: SwiftUI.LayoutSubviews,
                     cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? max(0, x - spacing), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: SwiftUI.LayoutSubviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Coverage note above the results: why a search may be missing
/// appearance-only matches, or that no sufficiently relevant match was found.
/// Replaces the popover that used to hang off the removed control row.
struct SearchCoverageNotice: View {
    @Environment(ThemeStore.self) private var theme

    let title: String?
    let details: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(Typography.label)
                        .foregroundStyle(theme.textPrimary)
                }
                Text(details)
                    .font(Typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.selectionFill.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.content))
        .themedBorder(Radius.content)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }
}
