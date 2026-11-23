import AppKit
import Photos
import SwiftUI

/// First-run setup wizard guiding clean Macs through Photos access and
/// zero-terminal Vision indexing. Can also be reopened from the landing screen
/// via "Quick Index". Styling mirrors the modal shell used across the app.
struct OnboardingView: View {
    @Bindable var ui: UIState
    let indexer: NativeIndexerStore?
    let onProgress: (@MainActor @Sendable () -> Void)?
    let onFinished: (() -> Void)?

    @Environment(ThemeStore.self) private var theme
    @State private var ownedIndexer = NativeIndexerStore()

    init(
        ui: UIState,
        indexer: NativeIndexerStore? = nil,
        onProgress: (@MainActor @Sendable () -> Void)? = nil,
        onFinished: (() -> Void)? = nil
    ) {
        self.ui = ui
        self.indexer = indexer
        self.onProgress = onProgress
        self.onFinished = onFinished
    }

    private var activeIndexer: NativeIndexerStore {
        indexer ?? ownedIndexer
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                stepCard(
                    number: "1",
                    title: "Connect Apple Photos (read-only)",
                    subtitle: "Photo Search reads your library on this Mac to index text, scenes, and videos locally."
                ) {
                    HStack(spacing: 10) {
                        Label(activeIndexer.authorizationLabel, systemImage: authIcon)
                            .font(Typography.control)
                            .foregroundStyle(activeIndexer.isAuthorized ? Color.green : theme.textSecondary)

                        Spacer()

                        if activeIndexer.authorizationStatus == .denied
                            || activeIndexer.authorizationStatus == .restricted {
                            Button("Open Privacy Settings") {
                                openPhotosPrivacySettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointerStyle(.link)
                        } else if !activeIndexer.isAuthorized {
                            Button("Grant Photos Access") {
                                Task { await activeIndexer.requestAuthorization() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accent)
                            .controlSize(.small)
                            .pointerStyle(.link)
                        }
                    }
                }

                stepCard(
                    number: "2",
                    title: "Build Local Search Index (no terminal required)",
                    subtitle: "Runs on-device with Apple Vision OCR & classification. Existing Qwen/VLM annotations are never overwritten."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button("Index Recent 200") {
                                activeIndexer.startIndexing(limit: 200, onProgressBatch: onProgress)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accent)
                            .controlSize(.regular)
                            .disabled(activeIndexer.isIndexing)
                            .pointerStyle(.link)

                            Button("Index Full Library") {
                                activeIndexer.startIndexing(limit: nil, onProgressBatch: onProgress)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(activeIndexer.isIndexing)
                            .pointerStyle(.link)

                            Spacer()

                            if activeIndexer.isIndexing {
                                Button("Stop") {
                                    activeIndexer.stopIndexing()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .pointerStyle(.link)
                            }
                        }

                        if activeIndexer.isIndexing || activeIndexer.processedCount > 0 {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(
                                    value: Double(activeIndexer.processedCount),
                                    total: Double(max(1, activeIndexer.totalCount))
                                )
                                .progressViewStyle(.linear)
                                .tint(theme.accent)

                                HStack {
                                    Text(activeIndexer.statusMessage)
                                        .font(Typography.footnote)
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(1)
                                    Spacer()
                                    if activeIndexer.totalCount > 0 {
                                        Text("\(activeIndexer.processedCount.formatted()) / \(activeIndexer.totalCount.formatted())")
                                            .font(Typography.footnote)
                                            .foregroundStyle(theme.textSecondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }

                        if let error = activeIndexer.lastError {
                            Text(error)
                                .font(Typography.footnote)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                stepCard(
                    number: "3",
                    title: "Optional Upgrades",
                    subtitle: "Connect a VLM in Settings → Models for rich descriptions, download Qwen3-VL-Embedding-2B (4.6 GB) in Settings → Visual Search, or search from Raycast via sp and sv."
                ) {
                    EmptyView()
                }

                HStack {
                    Button("Skip for Now") { finish() }
                        .buttonStyle(.plain)
                        .font(Typography.control)
                        .foregroundStyle(theme.textSecondary)
                        .pointerStyle(.link)

                    Spacer()

                    Button("Start Searching") { finish() }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.accent)
                        .controlSize(.large)
                        .focusEffectDisabled()
                        .pointerStyle(.link)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(width: 560)
            .background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .themedBorder(Radius.panel)
            .shadow(color: .black.opacity(0.32), radius: 28, y: 12)
            // Esc completes too so dismissing without clicking Start Searching
            // does not leave the modal stuck open on relaunch.
            .background {
                Button("Close") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .pointerStyle(.default)
        .task {
            activeIndexer.refreshAuthorization()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconView()
                .scaleEffect(56 / 1024)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Photo Search")
                    .font(Typography.title)
                    .foregroundStyle(theme.textPrimary)
                Text("Private, 100% local search across your Apple Photos & Videos and Raycast.")
                    .font(Typography.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }

    private var authIcon: String {
        switch activeIndexer.authorizationStatus {
        case .authorized, .limited: "checkmark.circle.fill"
        case .denied, .restricted: "exclamationmark.triangle.fill"
        default: "photo.badge.plus"
        }
    }

    private func stepCard<Actions: View>(
        number: String,
        title: String,
        subtitle: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(number)
                    .font(Typography.control)
                    .foregroundStyle(theme.accent)
                    .frame(width: 22, height: 22)
                    .background(theme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Typography.label)
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            actions()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.content))
        .themedBorder(Radius.content)
    }

    private func finish() {
        ui.completeOnboarding()
        onFinished?()
    }

    private func openPhotosPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    OnboardingView(ui: UIState())
        .frame(width: 800, height: 680)
        .environment(ThemeStore())
}
