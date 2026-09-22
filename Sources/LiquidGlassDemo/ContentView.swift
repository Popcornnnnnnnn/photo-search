import AppKit
import SwiftUI

struct ContentView: View {
    let backdrop: MeshBackdrop
    let card: GlassCardModel
    let windowMaterial: NSVisualEffectView.Material?

    @State private var model = TransparencyModel()
    @State private var ui: UIState
    @State private var systemAppearance = SystemAppearance()
    @State private var errors = ErrorStore()
    @State private var a11y = AccessibilitySettings()
    @State private var store = PhotoSearchStore()
    @State private var searchHistory = SearchHistoryStore()
    @State private var landingQuery = ""
    @State private var hasEnteredSearch = false

    @Environment(ThemeStore.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(backdrop: MeshBackdrop = .demo,
         card: GlassCardModel = .demo,
         windowMaterial: NSVisualEffectView.Material? = .sidebar,
         showsOnboarding: Bool = false) {
        self.backdrop = backdrop
        self.card = card
        self.windowMaterial = windowMaterial
        _ui = State(initialValue: UIState(showsOnboarding: showsOnboarding))
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: ui.leftSidebarVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: ui.rightSidebarVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hasEnteredSearch)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: Layout.hairline)
                    .ignoresSafeArea()
            }
            .overlay {
                if ui.showSettings {
                    SettingsModal(model: model, ui: ui, a11y: a11y)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: ui.showSettings)
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
            .task(id: "\(store.section.rawValue)|\(store.query)") {
                if !store.query.isEmpty {
                    try? await Task.sleep(for: .milliseconds(220))
                    guard !Task.isCancelled else { return }
                }
                store.reload()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { return }
                    store.reload(showLoading: false)
                }
            }
    }

    private var appContent: some View {
        ZStack {
            // Keep the window canvas opaque beneath the full-size titlebar.
            // Otherwise macOS' titlebar material samples the desktop and creates
            // a mismatched grey strip above each translucent sidebar.
            theme.background.ignoresSafeArea()

            if hasEnteredSearch || store.isViewerPresented {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if ui.leftSidebarVisible {
                            SidebarTint()
                                .frame(width: ui.leftSidebarWidth)
                                .overlay { PhotoSidebar(store: store, ui: ui) }
                                .overlay(alignment: .trailing) {
                                    ResizableColumnDivider(
                                        ui: ui,
                                        edge: .leading,
                                        collapseAction: {
                                            ui.leftSidebarVisible = false
                                        }
                                    )
                                }
                                .zIndex(2)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }

                        mainColumn

                        if store.isViewerPresented ? store.viewerInfoVisible : ui.rightSidebarVisible {
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
                                        edge: .trailing,
                                        collapseAction: {
                                            if store.isViewerPresented {
                                                store.viewerInfoVisible = false
                                            } else {
                                                ui.rightSidebarVisible = false
                                            }
                                        }
                                    )
                                }
                                .zIndex(2)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .ignoresSafeArea(edges: .top)
                .transition(.opacity)
            } else {
                landingView
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
    }

    private var landingView: some View {
        ZStack {
            landingBackground

            PhotoLandingSearchView(query: $landingQuery, history: searchHistory) {
                beginSearch()
            }
            .padding(.horizontal, 48)
            .offset(y: -36)
        }
        .overlay {
            PointerEffectsOverlay(reduceMotion: reduceMotion || a11y.reduceMotion)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landingBackground: some View {
        ZStack {
            theme.background

            RadialGradient(
                colors: [theme.accent.opacity(0.13), .clear],
                center: UnitPoint(x: 0.46, y: 0.43),
                startRadius: 24,
                endRadius: 520
            )

            RadialGradient(
                colors: [Color.cyan.opacity(0.055), .clear],
                center: UnitPoint(x: 0.64, y: 0.38),
                startRadius: 18,
                endRadius: 390
            )

            LinearGradient(
                colors: [.white.opacity(0.035), .clear, .black.opacity(0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func beginSearch() {
        let query = landingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        store.photos = []
        store.resultCount = 0
        store.selectedID = nil
        store.isLoading = true
        store.section = .all
        store.query = query
        ui.leftSidebarVisible = false
        ui.rightSidebarVisible = false
        hasEnteredSearch = true
    }

    private var mainColumn: some View {
        ZStack {
            canvasBackground
            if store.isViewerPresented {
                PhotoOneUpView(
                    store: store,
                    reservesWindowControls: !ui.leftSidebarVisible
                )
            } else {
                VStack(spacing: 0) {
                    PhotoSearchBar(store: store, history: searchHistory) {
                        returnToLanding()
                    }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                    PhotoGrid(store: store) {
                        ui.rightSidebarVisible = true
                    }
                }
            }
        }
        .overlay(alignment: .leading) {
            if !ui.leftSidebarVisible && !store.isViewerPresented {
                SidebarEdgeActivator(
                    tooltip: "Show sidebar",
                    edge: .leading
                ) {
                    ui.leftSidebarVisible = true
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !ui.rightSidebarVisible && !store.isViewerPresented {
                SidebarEdgeActivator(
                    tooltip: "Show info",
                    edge: .trailing
                ) {
                    ui.rightSidebarVisible = true
                }
            }
        }
        .overlay {
            if !store.isViewerPresented {
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
        landingQuery = ""
        store.query = ""
        store.section = .all
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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.alphaValue = 1
        window.titleVisibility = .hidden
        window.title = "Photo Search"
        window.styleMask.insert([.titled, .resizable, .miniaturizable, .closable, .fullSizeContentView])
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        if window.frameAutosaveName.isEmpty {
            window.setFrameUsingName(Prefs.mainWindowFrame, force: true)
            window.setFrameAutosaveName(Prefs.mainWindowFrame)
        }

    }
}

#Preview {
    ContentView(windowMaterial: nil)
        .frame(width: 1280, height: 820)
        .environment(ThemeStore())
}
