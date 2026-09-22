import SwiftUI

struct PhotoSidebar: View {
    @Environment(ThemeStore.self) private var theme
    let store: PhotoSearchStore
    @Bindable var ui: UIState

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
                    store.section = section
                }
            }

            Spacer()

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
                        .fill(.green)
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
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if selected || hovering {
            if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(theme.panel.opacity(selected ? 0.20 : 0.12))
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: Radius.row))
            } else {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(selected ? theme.selectionFill : theme.hoverFill)
            }
        }
    }
}

struct PhotoSearchBar: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: PhotoSearchStore
    let history: SearchHistoryStore
    let onEmpty: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var clearHovering = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(focused ? theme.accent : theme.textSecondary)

            TextField("Search people, places, text, screenshots…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { history.record(store.query) }

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

            SearchHistoryButton(history: history) { query in
                history.record(query)
                store.query = query
            }

            Rectangle()
                .fill(theme.divider.opacity(0.75))
                .frame(width: Layout.hairline, height: 16)

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
        .frame(maxWidth: 660)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
        .onChange(of: store.query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onEmpty()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .animation(.easeOut(duration: 0.16), value: focused)
    }

    private var resultCountLabel: String {
        if store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.section.countDescription(store.resultCount)
        }
        return "\(store.resultCount.formatted()) results"
    }
}

struct PhotoLandingSearchView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var query: String
    let history: SearchHistoryStore
    let onSubmit: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var submitHovering = false
    @State private var rainbowPhase = 0.0
    @State private var pointerPhase = 0.0
    @State private var pointerPosition = UnitPoint.center

    private var canSubmit: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                Text("Photo Search")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                Text("Search your Photos by meaning, text, or moment.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.bottom, 28)

            searchField
        }
        .frame(maxWidth: 720)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(focused ? theme.accent : theme.textSecondary)

            TextField("Search people, moments, text, or anything…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit(submit)

            SearchHistoryButton(history: history) { previousQuery in
                query = previousQuery
                submit()
            }

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSubmit ? Color.white : theme.textSecondary.opacity(0.65))
                    .frame(width: 30, height: 30)
                    .background(
                        canSubmit
                            ? theme.accent.opacity(submitHovering ? 1 : 0.88)
                            : theme.textSecondary.opacity(0.10),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .disabled(!canSubmit)
            .help("Search")
            .accessibilityLabel("Search")
            .onHover { submitHovering = $0 }
        }
        .padding(.horizontal, 19)
        .frame(height: 56)
        .modifier(SearchGlassSurface(active: focused, hovering: hovering))
        .background {
            ZStack {
                Capsule()
                    .fill(theme.accent.opacity(focused ? 0.075 : (hovering ? 0.05 : 0.025)))
                    .blur(radius: focused ? 24 : 18)
                    .padding(-7)

                Capsule()
                    .stroke(rainbowGradient, lineWidth: focused ? 9 : 6)
                    .blur(radius: focused ? 13 : 10)
                    .opacity(rainbowOpacity * 0.38)
                    .padding(-3)

                RadialGradient(
                    colors: [.white.opacity(0.24), theme.accent.opacity(0.08), .clear],
                    center: pointerPosition,
                    startRadius: 0,
                    endRadius: 170
                )
                .clipShape(Capsule())
                .opacity(hovering ? 0.75 : 0)
            }
        }
        .overlay {
            ZStack {
                Capsule()
                    .strokeBorder(
                        theme.textPrimary.opacity(hovering || focused ? 0.10 : 0.055),
                        lineWidth: 1
                    )

                Capsule()
                    .strokeBorder(
                        rainbowGradient,
                        lineWidth: focused ? 2.1 : (hovering ? 1.7 : 1.15)
                    )
                    .opacity(rainbowOpacity)

                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.32), .white.opacity(0.06), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: Layout.hairline
                    )
                    .padding(1)
            }
        }
        .shadow(
            color: focused ? theme.accent.opacity(0.14) : .black.opacity(hovering ? 0.10 : 0.06),
            radius: focused ? 17 : (hovering ? 11 : 7),
            y: 3
        )
        .scaleEffect(hovering && !focused ? 1.004 : 1)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hovering = true
                let x = min(max(location.x / 720, 0), 1)
                let y = min(max(location.y / 56, 0), 1)
                pointerPosition = UnitPoint(x: x, y: y)
                pointerPhase = (x - 0.5) * 150 + (y - 0.5) * 36
            case .ended:
                hovering = false
                pointerPosition = .center
                pointerPhase = 0
            }
        }
        .task {
            focused = true
            guard !reduceMotion else { return }
            rainbowPhase = 0
            withAnimation(.linear(duration: 10).repeatForever(autoreverses: false)) {
                rainbowPhase = 360
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: pointerPosition)
        .animation(.easeOut(duration: 0.16), value: focused)
    }

    private func submit() {
        guard canSubmit else { return }
        history.record(query)
        onSubmit()
    }

    private var rainbowOpacity: Double {
        if focused { return 0.82 }
        if hovering { return 0.60 }
        return 0.24
    }

    private var rainbowGradient: AngularGradient {
        AngularGradient(
            colors: [
                Color(hex: 0x4285F4),
                Color(hex: 0x65D5F2),
                Color(hex: 0xA142F4),
                Color(hex: 0xEA4335),
                Color(hex: 0xFBBC04),
                Color(hex: 0x34A853),
                Color(hex: 0x4285F4)
            ],
            center: pointerPosition,
            startAngle: .degrees(rainbowPhase + pointerPhase),
            endAngle: .degrees(rainbowPhase + pointerPhase + 360)
        )
    }
}

private struct SearchHistoryButton: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let history: SearchHistoryStore
    let onSelect: (String) -> Void

    @State private var isPresented = false
    @State private var hovering = false

    var body: some View {
        if !history.entries.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        hovering || isPresented
                            ? theme.textPrimary
                            : theme.textSecondary.opacity(0.52)
                    )
                    .frame(width: 28, height: 28)
                    .background(
                        hovering || isPresented ? theme.hoverFill : .clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Search history")
            .accessibilityLabel("Search history")
            .accessibilityValue("\(history.entries.count) saved searches")
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                SearchHistoryPopover(
                    entries: history.recentEntries,
                    onSelect: { query in
                        isPresented = false
                        onSelect(query)
                    },
                    onRemove: { query in
                        history.remove(query)
                        if history.entries.isEmpty { isPresented = false }
                    },
                    onClear: {
                        history.clear()
                        isPresented = false
                    }
                )
            }
        }
    }
}

private struct SearchHistoryPopover: View {
    @Environment(ThemeStore.self) private var theme

    let entries: [String]
    let onSelect: (String) -> Void
    let onRemove: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recent Searches", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)

                Spacer()

                Button("Clear History", action: onClear)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .pointerStyle(.link)
            }

            VStack(spacing: 2) {
                ForEach(entries, id: \.self) { entry in
                    SearchHistoryRow(
                        query: entry,
                        onSelect: { onSelect(entry) },
                        onRemove: { onRemove(entry) }
                    )
                }
            }
        }
        .padding(12)
        .frame(width: 390)
    }
}

private struct SearchHistoryRow: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let query: String
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary.opacity(0.72))

                    Text(query)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Remove from history")
            .accessibilityLabel("Remove \(query) from history")
            .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(hovering ? theme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
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
    let onSelection: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 16)]

    var body: some View {
        @Bindable var store = store
        ScrollableContent {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.photos) { photo in
                    PhotoCard(
                        photo: photo,
                        selected: store.selectedID == photo.id
                    )
                        .onTapGesture(count: 2) { store.openViewer(for: photo) }
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                store.selectedID = photo.id
                                onSelection()
                            }
                        )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .overlay {
            if store.isLoading && store.photos.isEmpty {
                ProgressView("Loading photo index…")
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if let error = store.errorMessage {
                ContentUnavailableView("Unable to open the photo index",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if store.photos.isEmpty {
                ContentUnavailableView.search(text: store.query)
            }
        }
    }
}

private struct PhotoCard: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let photo: IndexedPhoto
    let selected: Bool

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                PhotoThumbnailView(
                    path: photo.thumbnailPath,
                    maxPixelSize: 480
                )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Text(photo.displayAssetType)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay {
                                Capsule()
                                    .strokeBorder(.white.opacity(0.16), lineWidth: Layout.hairline)
                            }
                            .padding(9)
                    }
            }
            .frame(height: 164)

            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .background(
            theme.panel.opacity(hovering ? 0.94 : 0.82),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    selected
                        ? theme.accent.opacity(0.9)
                        : (hovering ? theme.accent.opacity(0.34) : theme.border.opacity(0.32)),
                    lineWidth: selected ? 1.5 : Layout.hairline
                )
        }
        .shadow(
            color: .black.opacity(selected ? 0.14 : (hovering ? 0.10 : 0.025)),
            radius: selected ? 8 : (hovering ? 9 : 2),
            y: hovering ? 4 : 1
        )
        .scaleEffect(hovering && !reduceMotion ? 1.006 : 1)
        .offset(y: hovering && !reduceMotion ? -1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }

    private var caption: String {
        photo.shortCaption.isEmpty ? photo.filename : photo.shortCaption
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
                            .buttonStyle(.plain)
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
                DisclosureGroup(isExpanded: $showsFullDescription) {
                    Text(display(full))
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                } label: {
                    Label("Full model description", systemImage: "text.alignleft")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
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
    let store: PhotoSearchStore
    var reservesWindowControls = false

    @FocusState private var focused: Bool
    @State private var zoom: CGFloat = 1
    @State private var magnificationBase: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var dragBase: CGSize?
    @State private var didCopyImage = false
    @State private var copyFeedbackGeneration = 0
    @State private var pagingOffset: CGFloat = 0
    @State private var pagingSettling = false

    var body: some View {
        VStack(spacing: 0) {
            viewerToolbar
            Rectangle().fill(theme.divider).frame(height: Layout.hairline)

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

    private var viewerToolbar: some View {
        ZStack {
            if let photo = store.selectedPhoto {
                VStack(spacing: 1) {
                    Text(photo.displayCapturedAt ?? photo.filename)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    if let position = store.selectedPositionLabel {
                        Text(position)
                            .font(.caption2)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: 320)
            }

            HStack(spacing: 12) {
                ViewerBackButton {
                    store.closeViewer()
                }

                Spacer()

                ViewerToolbarButton(
                    systemImage: didCopyImage ? "checkmark" : "doc.on.doc",
                    tooltip: didCopyImage ? "Copied" : "Copy Image"
                ) {
                    copySelectedImage()
                }

                ViewerToolbarButton(
                    systemImage: store.viewerInfoVisible ? "info.circle.fill" : "info.circle",
                    tooltip: store.viewerInfoVisible ? "Hide info" : "Show info"
                ) {
                    store.viewerInfoVisible.toggle()
                }
            }
            .padding(.leading, reservesWindowControls ? Layout.leadingAccessoryWidth + 108 : 14)
            .padding(.trailing, Layout.trailingAccessoryWidth + 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .photoGlassSurface(radius: 0, tintOpacity: 0.12)
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

    private func viewerPhoto(_ photo: IndexedPhoto,
                             canvasSize: CGSize,
                             selected: Bool = false) -> some View {
        PhotoThumbnailView(
            path: FileManager.default.fileExists(atPath: photo.filePath)
                ? photo.filePath
                : photo.thumbnailPath,
            contentMode: .fit,
            maxPixelSize: 3200
        )
        .scaleEffect(selected ? zoom : 1)
        .offset(selected ? panOffset : .zero)
        .padding(24)
        .frame(width: canvasSize.width, height: canvasSize.height)
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

private struct ViewerBackButton: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.left")
                .font(.callout.weight(.medium))
                .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    hovering ? theme.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Back to photos (Esc)")
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}

private struct ViewerToolbarButton: View {
    @Environment(ThemeStore.self) private var theme
    let systemImage: String
    let tooltip: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                .frame(width: 28, height: 26)
                .background(hovering ? theme.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(tooltip)
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
