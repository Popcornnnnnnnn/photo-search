import AppKit
import SwiftUI

struct RandomBrowseView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: RandomBrowseStore
    let onClose: () -> Void
    let onLocate: (RandomBrowsePhoto) -> Void
    var additionalReduceMotion = false

    private var motionReduced: Bool { reduceMotion || additionalReduceMotion }

    @FocusState private var focused: Bool
    @State private var pagingOffset: CGFloat = 0
    @State private var isNavigating = false
    @State private var canvasWidth: CGFloat = 1
    @State private var pendingDirections: [Int] = []
    @State private var didCopyImage = false
    @State private var rotationQuarterTurns = 0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    theme.background
                    if let image = store.previousImage, store.canGoBack {
                        photo(image, size: proxy.size)
                            .offset(x: pagingOffset - proxy.size.width)
                            .accessibilityHidden(true)
                    }
                    if let image = store.currentImage, store.currentID != nil {
                        photo(image, size: proxy.size, turns: rotationQuarterTurns)
                            .offset(x: pagingOffset)
                    } else {
                        stateMessage
                    }
                    if let image = store.nextImage {
                        photo(image, size: proxy.size)
                            .offset(x: pagingOffset + proxy.size.width)
                            .accessibilityHidden(true)
                    }

                    TrackpadPagingObserver(onChanged: { translation in
                        guard !isNavigating else { return }
                        if translation == 0 { store.refreshPreparedCandidate() }
                        let limited = min(proxy.size.width, max(-proxy.size.width, translation))
                        pagingOffset = limited > 0 && !store.canGoBack ? limited * 0.18 : limited
                    }, onEnded: {
                        let threshold = min(120, proxy.size.width * 0.18)
                        if pagingOffset >= threshold && store.canGoBack {
                            navigateBack()
                        } else if pagingOffset <= -threshold {
                            navigateNext()
                        } else {
                            withAnimation(motionReduced ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.88)) {
                                pagingOffset = 0
                            }
                        }
                    })
                    .accessibilityHidden(true)

                    HStack {
                        if store.canGoBack {
                            arrow("Previous viewed photo", systemImage: "chevron.left", action: navigateBack)
                        }
                        Spacer()
                        if store.currentImage != nil && store.status != .exhausted {
                            arrow("Another random photo", systemImage: "chevron.right", action: navigateNext)
                        }
                    }
                    .padding(.horizontal, 16)

                }
                .clipped()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
            }

            if let photo = store.currentPhoto {
                photoDetails(photo, displayDate: store.currentDisplayDate)
                    .frame(minHeight: 76)
                    .frame(maxWidth: .infinity)
                    .background(theme.background)
                    .overlay(alignment: .top) {
                        theme.divider.frame(height: Layout.hairline)
                    }
            }
        }
        .toolbar { browseToolbar }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: store.currentID) { _, id in
            didCopyImage = false
            rotationQuarterTurns = 0
            if let id { store.didDisplayCurrent(id) }
        }
        .onKeyPress(.leftArrow) {
            navigateBack()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateNext()
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .task { await store.start() }
    }

    @ToolbarContentBuilder
    private var browseToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ViewerBackButton(tooltip: "Back to Library (Esc)", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
        }
        ToolbarItem(placement: .principal) {
            Text("Browse randomly").font(.headline)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ViewerToolbarButton(systemImage: "rotate.right", tooltip: "Rotate Clockwise") {
                withAnimation(motionReduced ? nil : .easeInOut(duration: 0.2)) {
                    rotationQuarterTurns += 1
                }
            }.disabled(store.currentImage == nil)
            ViewerToolbarButton(systemImage: didCopyImage ? "checkmark" : "doc.on.doc",
                                tooltip: didCopyImage ? "Copied" : "Copy Image") {
                guard let image = store.currentImage else { return }
                NSPasteboard.general.clearContents()
                didCopyImage = NSPasteboard.general.writeObjects([image])
            }.disabled(store.currentImage == nil)
        }
    }

    private func photo(_ image: NSImage, size: CGSize, turns: Int = 0) -> some View {
        let availableWidth = max(0, size.width - 48)
        let availableHeight = max(0, size.height - 48)
        return FittedRotatingImage(image: image, rotationDegrees: Double(turns * 90))
            .frame(width: availableWidth, height: availableHeight)
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("Photo")
    }

    private var stateMessage: some View {
        VStack(spacing: 16) {
            switch store.status {
            case .loading:
                Text("Preparing photos…")
            case .empty:
                Text("There are no local photos to show.")
            case .unavailable:
                Text("The photo library is unavailable.")
            case .exhausted:
                Text("You've seen all photos available for this round.")
                Button("Start another round") {
                    Task { await store.restartRound() }
                }
            case .ready:
                EmptyView()
            }
        }
        .foregroundStyle(theme.textSecondary)
    }

    private func arrow(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        RandomBrowseArrow(label: label, systemImage: systemImage, action: action)
    }

    private func photoDetails(_ photo: RandomBrowsePhoto, displayDate: String) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayDate)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(photo.shortCaption.flatMap { $0.isEmpty ? nil : $0 } ?? photo.filename)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.status == .exhausted {
                Button("Start another round") {
                    Task { await store.restartRound() }
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(theme.accent)
            }
            Button {
                onLocate(photo)
            } label: {
                Label("Locate in Library", systemImage: "calendar")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(HoverButtonStyle())
            .foregroundStyle(theme.accent)
            .disabled(photo.assetType == nil && photo.capturedAt == nil)
            .help("Open this photo in Library, or its nearby date if not yet indexed")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func navigateBack() {
        if isNavigating {
            if pendingDirections.count < 8 { pendingDirections.append(-1) }
            return
        }
        guard store.canGoBack else { return }
        isNavigating = true
        Task {
            if await store.preparePrevious() {
                finishNavigation(toward: canvasWidth,
                                 commit: { store.commitPreparedBack() },
                                 fallback: { await store.goBack() })
            } else {
                withAnimation(motionReduced ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.88)) {
                    pagingOffset = 0
                }
                isNavigating = false
                drainPendingDirections()
            }
        }
    }

    private func navigateNext() {
        if isNavigating {
            if pendingDirections.count < 8 { pendingDirections.append(1) }
            return
        }
        guard store.currentImage != nil, store.status != .exhausted else { return }
        isNavigating = true
        Task {
            if await store.prepareNext() {
                finishNavigation(toward: -canvasWidth,
                                 commit: { store.commitPreparedNext() },
                                 fallback: { await store.next() })
            } else {
                await store.next()
                pagingOffset = 0
                isNavigating = false
                drainPendingDirections()
            }
        }
    }

    private func finishNavigation(toward target: CGFloat,
                                  commit: @escaping () -> Bool,
                                  fallback: @escaping () async -> Void) {
        let complete: () -> Void = {
            Task {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                let committed = withTransaction(transaction) {
                    let result = commit()
                    pagingOffset = 0
                    return result
                }
                if !committed { await fallback() }
                isNavigating = false
                drainPendingDirections()
            }
        }
        if motionReduced || target == 0 {
            complete()
        } else {
            withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.90),
                          completionCriteria: .logicallyComplete) {
                pagingOffset = target
            } completion: {
                complete()
            }
        }
    }

    private func drainPendingDirections() {
        guard !pendingDirections.isEmpty else { return }
        let direction = pendingDirections.removeFirst()
        if direction < 0 { navigateBack() } else { navigateNext() }
    }
}

private struct RandomBrowseArrow: View {
    let label: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.primary.opacity(hovering ? 0.8 : 0.28))
                .frame(width: 46, height: 80)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel(label)
        .help(label)
        .onHover { hovering = $0 }
    }
}
