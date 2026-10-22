import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    let backdrop: MeshBackdrop
    let card: GlassCardModel
    let windowMaterial: NSVisualEffectView.Material?
    /// False in the `--snapshot` path: `ImageRenderer` degrades the whole frame to
    /// a system placeholder as soon as the tree hosts an `NSViewRepresentable`, and
    /// the pointer overlay is an AppKit bridge. Ripples only appear on click, so
    /// the offscreen render loses nothing.
    let showsPointerEffects: Bool

    @State private var model = TransparencyModel()
    @State private var ui: UIState
    @State private var systemAppearance = SystemAppearance()
    @State private var errors = ErrorStore()
    @State private var a11y = AccessibilitySettings()
    @State private var store = PhotoSearchStore()
    @State private var randomBrowse = RandomBrowseStore()
    @State private var randomBrowsePresented = false
    @State private var photoReviewPresented = false
    @State private var resolvingLibraryJump = false
    @State private var pendingLibraryJump: RandomBrowsePhoto?
    @State private var libraryJumpID: String?
    @State private var libraryJumpToken = 0
    @State private var libraryJumpNotice: String?
    @State private var searchHistory = SearchHistoryStore()
    @State private var connection = PhotoConnectionStore()
    @State private var indexActivity = PhotoIndexActivityStore()
    @State private var encoder = PhotoEncoderStore()
    @State private var landingQuery = ""
    @State private var hasEnteredSearch = false
    @State private var thumbnailContentMode: ContentMode = .fill

    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(backdrop: MeshBackdrop = .demo,
         card: GlassCardModel = .demo,
         windowMaterial: NSVisualEffectView.Material? = .sidebar,
         showsOnboarding: Bool = false,
         showsPointerEffects: Bool = true,
         startsInLibrary: Bool = false,
         opensSettingsSection: SettingsSection? = nil) {
        self.backdrop = backdrop
        self.card = card
        self.windowMaterial = windowMaterial
        self.showsPointerEffects = showsPointerEffects
        _hasEnteredSearch = State(initialValue: startsInLibrary)
        let initialState = UIState(showsOnboarding: showsOnboarding)
        if let opensSettingsSection {
            initialState.settingsSection = opensSettingsSection
            initialState.showSettings = true
        }
        _ui = State(initialValue: initialState)
    }

    private var effectiveScheme: ColorScheme {
        switch ui.mode {
        case .light: .light
        case .dark: .dark
        case .system: systemAppearance.colorScheme
        }
    }

    var body: some View {
        appContent
            .disabled(ui.showSettings)
            .toolbar { libraryToolbar }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hasEnteredSearch)
            .overlay {
                if ui.showSettings {
                    SettingsModal(model: model, ui: ui, a11y: a11y, history: searchHistory,
                                  encoder: encoder, indexActivity: indexActivity) { entry in
                        ui.showSettings = false
                        beginSearch(entry.query, section: entry.section)
                    }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: ui.showSettings)
            // The encoder host also exits when its stdin closes, so a crash still
            // releases the model; this just makes the normal quit explicit.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                encoder.shutdown()
            }
            .overlay(alignment: .bottom) {
                if let issue = connection.issue {
                    PhotoConnectionNotice(issue: issue, isChecking: connection.isChecking) {
                        ModelProviderSettings.resumeWorker()
                        Task { await connection.refresh() }
                    } onSettings: {
                        ui.showSettings = true
                        ui.settingsSection = .models
                    }
                    .frame(maxWidth: 640)
                    .padding(24)
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: connection.issue)
            .focusedSceneValue(\.uiState, ui)
            .focusedSceneValue(\.transparencyModel, model)
            .focusedSceneValue(\.accessibilitySettings, a11y)
            .environment(\.reduceTransparencyOverride, a11y.reduceTransparency)
            .environment(\.increaseContrastOverride, a11y.increaseContrast)
            .environment(errors)
            .alert(errors.current?.title ?? "", isPresented: Binding(
                get: { errors.current != nil },
                set: { if !$0 { errors.dismiss() } }
            )) {
                Button("OK") { errors.dismiss() }
            } message: {
                if let current = errors.current { Text(current.message) }
            }
            .onOpenURL(perform: handle)
            .preferredColorScheme(effectiveScheme)
            .background {
                if let windowMaterial {
                    WindowConfigurator(version: effectiveScheme, material: windowMaterial) {
                        configure($0)
                    }
                }
            }
            .task(id: FilterSelection(section: store.section, time: store.timeFilter)) {
                store.reload(onlyIfChanged: true, encoder: encoder)
            }
            .task {
                while !Task.isCancelled {
                    await connection.refresh()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await connection.refresh() } }
            }
            .onChange(of: store.isLoading) { _, loading in
                if !loading { completeLibraryJump() }
            }
            .onChange(of: ui.showSettings) { _, isPresented in
                if !isPresented { Task { await connection.refresh() } }
            }
            .task {
                await indexActivity.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    await indexActivity.refresh()
                    if scenePhase == .active && hasEnteredSearch && !randomBrowsePresented && !photoReviewPresented {
                        await store.refreshIfChanged()
                    }
                }
            }
    }

    private struct FilterSelection: Hashable {
        let section: PhotoSection
        let time: PhotoTimeFilter
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if !photoReviewPresented && !randomBrowsePresented && !store.isViewerPresented {
            ToolbarItem(placement: .navigation) {
                if hasEnteredSearch {
                    ViewerToolbarButton(systemImage: "sidebar.left",
                                        tooltip: ui.leftSidebarVisible ? "Hide sidebar" : "Show sidebar",
                                        isActive: ui.leftSidebarVisible) {
                        ui.leftSidebarVisible.toggle()
                    }.disabled(ui.showSettings)
                }
            }
            ToolbarItem(placement: .principal) {
                if hasEnteredSearch {
                    PhotoSearchBar(store: store, history: searchHistory, encoder: encoder,
                                   thumbnailContentMode: $thumbnailContentMode) {
                        if pendingLibraryJump == nil { returnToLanding() }
                    }
                    .frame(minWidth: 300, idealWidth: 520, maxWidth: 660)
                    .disabled(ui.showSettings)
                } else {
                    Text("Photo Search").font(.headline)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                ViewerToolbarButton(systemImage: "gearshape", tooltip: "Settings") {
                    ui.showSettings = true
                }.disabled(ui.showSettings)
                if hasEnteredSearch {
                    ViewerToolbarButton(systemImage: "sidebar.right",
                                        tooltip: ui.rightSidebarVisible ? "Hide info" : "Show info",
                                        isActive: ui.rightSidebarVisible) {
                        ui.rightSidebarVisible.toggle()
                    }.disabled(ui.showSettings)
                }
            }
        }
    }

    private var appContent: some View {
        ZStack {
            // Only the backdrop extends behind the native toolbar; controls
            // and photo content respect its system-provided safe area.
            theme.background.ignoresSafeArea()

            if hasEnteredSearch || store.isViewerPresented {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if ui.leftSidebarVisible {
                            SidebarTint()
                                .frame(width: ui.leftSidebarWidth)
                                .overlay {
                                    PhotoSidebar(store: store, activity: indexActivity.activity, ui: ui, onRandomBrowse: {
                                        randomBrowsePresented = true
                                    }, onReview: { photoReviewPresented = true })
                                }
                                .overlay(alignment: .trailing) {
                                    ResizableColumnDivider(
                                        ui: ui,
                                        edge: .leading
                                    )
                                }
                                .zIndex(2)

                        }

                        mainColumn

                        if ui.rightSidebarVisible {
                            SidebarTint()
                                .frame(width: ui.rightSidebarWidth)
                                .overlay {
                                    PhotoInspector(
                                        store: store,
                                        showsThumbnail: !store.isViewerPresented
                                    )
                                }
                                .overlay(alignment: .leading) {
                                    ResizableColumnDivider(
                                        ui: ui,
                                        edge: .trailing
                                    )
                                }
                                .zIndex(2)

                        }
                    }
                }
                .transition(.opacity)
                .allowsHitTesting(!randomBrowsePresented && !photoReviewPresented)
                .accessibilityHidden(randomBrowsePresented || photoReviewPresented)
            } else {
                landingView
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    .allowsHitTesting(!randomBrowsePresented && !photoReviewPresented)
                    .accessibilityHidden(randomBrowsePresented || photoReviewPresented)
            }

            if photoReviewPresented {
                PhotoReviewView(encoder: encoder, thumbnailContentMode: thumbnailContentMode,
                                inspectorWidth: ui.rightSidebarWidth,
                                onClose: { photoReviewPresented = false }, onLocate: { photo in
                    photoReviewPresented = false
                    locateInLibrary(photo)
                }, onDeleted: { store.reload(showLoading: false, encoder: encoder) })
                .zIndex(3)
            }

            if randomBrowsePresented {
                RandomBrowseView(store: randomBrowse, onClose: {
                    randomBrowsePresented = false
                    enterLibrary()
                },
                                 onLocate: locateInLibrary,
                                 additionalReduceMotion: a11y.reduceMotion)
                    .zIndex(3)
            }
        }
    }

    private var landingView: some View {
        ZStack {
            landingBackground

            PhotoLandingSearchView(
                query: $landingQuery,
                encoder: encoder,
                indexedCount: store.stats.indexed,
                onSubmit: { beginSearch(landingQuery) },
                onBrowse: { enterLibrary() },
                onRandomBrowse: { randomBrowsePresented = true },
                onSettings: { ui.showSettings = true }
            )
            .padding(.horizontal, 48)
        }
        .overlay {
            if showsPointerEffects {
                PointerEffectsOverlay(reduceMotion: reduceMotion || a11y.reduceMotion)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landingBackground: some View {
        ZStack {
            theme.background

            RadialGradient(
                colors: [Color(hex: 0x2463EB).opacity(0.035), .clear],
                center: .center,
                startRadius: 24,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }

    private func beginSearch(_ value: String, section: PhotoSection = .all) {
        libraryJumpNotice = nil
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        store.photos = []
        store.resultCount = 0
        store.selectedID = nil
        store.isLoading = true
        store.closeViewer()
        store.section = section
        store.query = query
        store.submit(history: searchHistory, encoder: encoder)
        ui.leftSidebarVisible = false
        ui.rightSidebarVisible = false
        hasEnteredSearch = true
    }

    /// Enter the library without a query: the grid then shows every indexed photo,
    /// which is the only way in for someone who just wants to look around.
    private func enterLibrary(section: PhotoSection = .all) {
        libraryJumpNotice = nil
        landingQuery = ""
        store.closeViewer()
        store.section = section
        store.timeFilter = .all
        store.clearSearch()
        store.reload(encoder: encoder)
        hasEnteredSearch = true
    }

    private func locateInLibrary(_ photo: RandomBrowsePhoto) {
        pendingLibraryJump = photo
        randomBrowsePresented = false
        if hasEnteredSearch, store.submittedQuery.isEmpty, store.section == .all, store.timeFilter == .all,
           !store.photos.isEmpty, !store.isLoading {
            completeLibraryJump()
        } else {
            landingQuery = ""
            store.closeViewer()
            store.clearSearch()
            store.section = .all
            store.timeFilter = .all
            hasEnteredSearch = true
            store.reload(encoder: encoder)
        }
    }

    private func completeLibraryJump() {
        guard let photo = pendingLibraryJump, !store.isLoading else { return }
        if store.hasMore, !store.photos.contains(where: { $0.id == photo.id }) {
            guard !resolvingLibraryJump else { return }
            resolvingLibraryJump = true
            Task {
                await store.loadForLocation(id: photo.id, capturedAt: photo.capturedAt)
                resolvingLibraryJump = false
                finishLibraryJump(photo)
            }
            return
        }
        finishLibraryJump(photo)
    }

    private func finishLibraryJump(_ photo: RandomBrowsePhoto) {
        guard pendingLibraryJump?.id == photo.id else { return }
        pendingLibraryJump = nil
        guard let location = PhotoLibraryLocator.find(id: photo.id, capturedAt: photo.capturedAt,
                                                      in: store.photos) else {
            libraryJumpNotice = "This photo has no indexed date to locate in Library."
            return
        }
        if location.isExact {
            store.selectedID = location.id
            ui.rightSidebarVisible = true
            libraryJumpID = location.id
            libraryJumpNotice = nil
        } else {
            ui.rightSidebarVisible = false
            libraryJumpID = location.id
            libraryJumpNotice = "This photo is not indexed yet. Showing its place in the timeline."
        }
        libraryJumpToken += 1
    }

    private var mainColumn: some View {
        ZStack {
            canvasBackground
            // Keep the grid mounted so its scroll position and scrollbar metrics
            // survive opening and closing the viewer.
            VStack(spacing: 0) {
                if let libraryJumpNotice {
                    Text(libraryJumpNotice)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.bottom, 6)
                }

                PhotoGrid(store: store, encoder: encoder,
                          thumbnailContentMode: thumbnailContentMode,
                          scrollToPhotoID: libraryJumpID,
                          scrollToken: libraryJumpToken) { photo in
                    store.openViewer(for: photo)
                }
            }
            .opacity(store.isViewerPresented ? 0 : 1)
            .allowsHitTesting(!store.isViewerPresented)
            .accessibilityHidden(store.isViewerPresented)

            if store.isViewerPresented {
                PhotoOneUpView(
                    store: store,
                    infoVisible: $ui.rightSidebarVisible,
                    showsToolbar: !photoReviewPresented && !randomBrowsePresented,
                    sidebarVisible: ui.leftSidebarVisible,
                    onToggleSidebar: { ui.leftSidebarVisible.toggle() }
                )
            }
        }
        .overlay {
            if showsPointerEffects, !store.isViewerPresented {
                PointerEffectsOverlay(reduceMotion: reduceMotion || a11y.reduceMotion)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var canvasBackground: some View {
        ZStack {
            theme.background
            RadialGradient(
                colors: [theme.panel.opacity(0.34), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 620
            )
        }
    }

    private func returnToLanding() {
        libraryJumpNotice = nil
        landingQuery = ""
        store.clearSearch()
        store.section = .all
        store.timeFilter = .all
        ui.leftSidebarVisible = false
        ui.rightSidebarVisible = false
        hasEnteredSearch = false
    }

    private func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        switch link {
        case .theme(let id): theme.id = id
        }
    }

    private func configure(_ window: NSWindow) {
        window.appearance = NSAppearance(named: effectiveScheme == .dark ? .darkAqua : .aqua)
        window.isOpaque = true
        window.backgroundColor = theme.backgroundNSColor
        window.alphaValue = 1
        window.title = "Photo Search"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        if window.frameAutosaveName.isEmpty {
            window.setFrameUsingName(Prefs.mainWindowFrame, force: true)
            window.setFrameAutosaveName(Prefs.mainWindowFrame)
        }

    }
}

enum PhotoLibraryLocator {
    static func find(id: String, capturedAt: String?, in photos: [IndexedPhoto])
        -> (id: String, isExact: Bool)? {
        if let exact = photos.first(where: { $0.id == id }) { return (exact.id, true) }
        guard let capturedAt,
              let nearby = photos.first(where: { ($0.capturedAt ?? "") <= capturedAt })
                ?? photos.last else { return nil }
        return (nearby.id, false)
    }
}

#Preview {
    ContentView(windowMaterial: nil)
        .frame(width: 1280, height: 820)
        .environment(ThemeStore())
}
