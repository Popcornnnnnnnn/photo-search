import SwiftUI

/// The sections shown in the settings modal's left nav. Add a case (plus its
/// localized title/subtitle) to add a settings page.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case models = "Models"
    case appearance = "Appearance"
    case accessibility = "Accessibility"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .appearance: "paintpalette"
        case .accessibility: "accessibility"
        }
    }

    var title: String {
        switch self {
        case .general: L10n.general
        case .models: L10n.models
        case .appearance: L10n.appearance
        case .accessibility: L10n.accessibility
        }
    }

    var subtitle: String {
        switch self {
        case .general: L10n.generalHelp
        case .models: L10n.modelsHelp
        case .appearance: L10n.appearanceHelp
        case .accessibility: L10n.accessibilityHelp
        }
    }
}

/// Modal settings panel: dim backdrop + centered panel with a left section nav
/// and a scrollable content area (label+help rows with right-aligned controls).
struct SettingsModal: View {
    @Bindable var model: TransparencyModel
    @Bindable var ui: UIState
    @Bindable var a11y: AccessibilitySettings

    @Environment(ThemeStore.self) private var theme
    @Environment(ErrorStore.self) private var errors
    // Owned here (recreated on each open) so the toggle always reflects the
    // real SMAppService status, including changes made in System Settings.
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var providers = ModelProviderSettings()
    @State private var hoveredSection: SettingsSection?

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()
                .onTapGesture { close() }

            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(theme.divider).frame(width: Layout.hairline)
                content
            }
            .frame(maxWidth: 900, maxHeight: 720)
            .modifier(SettingsGlassSurface())
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
            .themedBorder(Radius.panel)
            .shadow(color: .black.opacity(0.34), radius: 30, y: 14)
            .overlay(alignment: .topTrailing) {
                IconButton(systemName: "xmark", tooltip: "Close") { close() }
                    .padding(12)
            }
            // Esc / ⌘. closes the modal (hidden button carrying the shortcut).
            .background {
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
            .padding(24)
        }
        // Reset the pointer for the modal's area (the cog's `.link` cursor would
        // otherwise stay "stuck" while occluded). Inner controls override this.
        .pointerStyle(.default)
        .sheet(isPresented: Binding(
            get: { providers.draftProvider != nil },
            set: { if !$0 { providers.cancelEditing() } }
        )) {
            providerEditorSheet
        }
    }

    private func close() { ui.showSettings = false }

    // MARK: Nav

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                navRow(item)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func navRow(_ item: SettingsSection) -> some View {
        Button {
            ui.settingsSection = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(Typography.icon).frame(width: 18)
                Text(item.title).font(Typography.body)
                Spacer()
            }
            .foregroundStyle(
                ui.settingsSection == item || hoveredSection == item
                    ? theme.textPrimary
                    : theme.textSecondary
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                settingsRowBackground(
                    selected: ui.settingsSection == item,
                    hovering: hoveredSection == item
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .onHover { hovering in hoveredSection = hovering ? item : nil }
        .animation(.easeOut(duration: 0.14), value: hoveredSection)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(ui.settingsSection == item ? .isSelected : [])
    }

    @ViewBuilder
    private func settingsRowBackground(selected: Bool, hovering: Bool) -> some View {
        if selected || hovering {
            if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(theme.panel.opacity(selected ? 0.18 : 0.10))
                    .glassEffect(.clear.interactive(), in: .rect(cornerRadius: Radius.row))
            } else {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(selected ? theme.selectionFill : theme.hoverFill)
            }
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollableContent {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ui.settingsSection.title).font(Typography.title).foregroundStyle(theme.textPrimary)
                    Text(ui.settingsSection.subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 16)

                switch ui.settingsSection {
                case .general: generalSection
                case .models: modelsSection
                case .appearance: appearanceSection
                case .accessibility: accessibilitySection
                }
            }
            // Extra top/right padding reserves space for the close icon
            // (top-right) and the scrollbar (right edge).
            .padding(.top, 22)
            .padding(.leading, 28)
            .padding(.trailing, 42)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generalSection: some View {
        settingRow(L10n.launchAtLogin,
                   launchAtLogin.available
                       ? L10n.launchAtLoginHelp
                       : L10n.launchAtLoginUnavailable) {
            Toggle(L10n.launchAtLogin, isOn: Binding(
                get: { launchAtLogin.enabled },
                set: { launchAtLogin.setEnabled($0, reporting: errors) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(theme.accent)
            .disabled(!launchAtLogin.available)
        }
    }

    private var appearanceSection: some View {
        Group {
            ThemePicker(ui: ui)
            rowDivider

            settingRow("Card Opacity",
                       "Fade just the glass card panel; the content stays readable.") {
                SliderControl(value: $model.cardOpacity,
                              range: OpacityControl.card.range,
                              percent: OpacityControl.card.percent(model.cardOpacity),
                              label: "Card Opacity")
            }
            rowDivider

            settingRow("Card Blur",
                       "Frost intensity of the glass backdrop behind the card.") {
                SliderControl(value: $model.blur,
                              range: TransparencyModel.blurRange,
                              percent: model.blurPercent,
                              label: "Card Blur")
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let active = providers.activeProvider {
                HStack(spacing: 12) {
                    Image(systemName: active.kind == .local ? "desktopcomputer" : "cloud")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.selectionFill, in: RoundedRectangle(cornerRadius: Radius.field))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active Provider")
                            .font(Typography.footnote)
                            .foregroundStyle(theme.textSecondary)
                        Text(active.name)
                            .font(Typography.label)
                            .foregroundStyle(theme.textPrimary)
                        Text(active.model)
                            .font(Typography.footnote)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Text(active.kind.title)
                        .font(Typography.control)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(theme.selectionFill, in: Capsule())
                }
                .padding(14)
                .background(theme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.content))
                .themedBorder(Radius.content)
            }

            Text("Providers")
                .font(Typography.label)
                .foregroundStyle(theme.textPrimary)
                .padding(.top, 4)

            VStack(spacing: 8) {
                ForEach(providers.configuration.providers) { provider in
                    providerListRow(provider)
                }
            }

            HStack {
                Button {
                    providers.beginAddingProvider()
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                Spacer()
                if !providers.savedMessage.isEmpty {
                    Text(providers.savedMessage)
                        .font(Typography.footnote)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func providerListRow(_ provider: ModelProviderProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: provider.kind == .local ? "desktopcomputer" : "cloud")
                .font(Typography.iconLarge)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(Typography.body)
                    .foregroundStyle(theme.textPrimary)
                Text(provider.model)
                    .font(Typography.footnote)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if provider.id == providers.configuration.activeProviderID {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(Typography.control)
                    .foregroundStyle(theme.success)
            } else {
                Button("Use") { activateProvider(provider) }
            }
            Button {
                providers.beginEditingProvider(provider)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit \(provider.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.background.opacity(0.32), in: RoundedRectangle(cornerRadius: Radius.field))
        .themedBorder(Radius.field)
    }

    private var providerEditorSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(providers.isAddingProvider ? "Add Provider" : "Edit Provider")
                        .font(Typography.title)
                        .foregroundStyle(theme.textPrimary)
                    Text(providers.isAddingProvider
                         ? "Create a new channel without changing the active provider."
                         : "Changes are saved only when you confirm below.")
                        .font(Typography.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                IconButton(systemName: "xmark", tooltip: "Cancel") { providers.cancelEditing() }
            }

            HStack(alignment: .top, spacing: 14) {
                editorField("Name", placeholder: "My model", keyPath: \.name)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Type").font(Typography.label).foregroundStyle(theme.textPrimary)
                    Picker("Type", selection: draftBinding(\.kind)) {
                        ForEach(ModelProviderKind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
            editorField("API Base URL", placeholder: "https://example.com/v1", keyPath: \.baseURL)
            editorField("Model", placeholder: "vision-model", keyPath: \.model)

            VStack(alignment: .leading, spacing: 5) {
                Text("API Key").font(Typography.label).foregroundStyle(theme.textPrimary)
                SecureField(
                    providers.draftHasStoredAPIKey ? "Stored in macOS Keychain" : "Optional for local endpoints",
                    text: $providers.draftAPIKey
                )
                .textFieldStyle(.roundedBorder)
                Text(providers.draftHasStoredAPIKey
                     ? "Leave blank to keep the saved key."
                     : "Keys are stored in macOS Keychain, not the configuration file.")
                    .font(Typography.footnote)
                    .foregroundStyle(theme.textSecondary)
            }

            DisclosureGroup("Advanced") {
                VStack(spacing: 10) {
                    editorToggle("Tailscale / SSH Bridge", isOn: draftBinding(\.requiresTailscale))
                    editorToggle("JSON Response Mode", isOn: draftBinding(\.jsonMode))
                    editorToggle("Qwen Thinking Control", isOn: draftBinding(\.qwenThinkingControl))
                    editorToggle("Reprocess Existing Photos", isOn: $providers.draftReprocessExisting)
                }
                .padding(.top, 10)
            }
            .font(Typography.body)
            .foregroundStyle(theme.textPrimary)

            HStack {
                if !providers.isAddingProvider,
                   providers.draftProvider?.id != providers.configuration.activeProviderID {
                    Button("Remove", role: .destructive) { deleteDraftProvider() }
                }
                Spacer()
                Text(providers.connectionState.message)
                    .font(Typography.footnote)
                    .foregroundStyle(providerStatusColor)
                Button("Test Connection") { Task { await providers.testDraftConnection() } }
                    .disabled(providers.connectionState == .testing)
                Button("Cancel") { providers.cancelEditing() }
                Button(providers.isAddingProvider ? "Add Provider" : "Save") { saveDraftProvider() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
            }
        }
        .padding(24)
        .frame(width: 590)
        .background(theme.panel)
    }

    private func editorField(
        _ title: String,
        placeholder: String,
        keyPath: WritableKeyPath<ModelProviderProfile, String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Typography.label).foregroundStyle(theme.textPrimary)
            TextField(placeholder, text: draftBinding(keyPath))
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    private func editorToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(Typography.body).foregroundStyle(theme.textPrimary)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
        }
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<ModelProviderProfile, Value>) -> Binding<Value> {
        Binding(
            get: { providers.draftProvider![keyPath: keyPath] },
            set: {
                guard var provider = providers.draftProvider else { return }
                provider[keyPath: keyPath] = $0
                providers.draftProvider = provider
                providers.connectionState = .idle
            }
        )
    }

    private var providerStatusColor: Color {
        switch providers.connectionState {
        case .failure: theme.danger
        case .success: theme.success
        default: theme.textSecondary
        }
    }

    private func saveDraftProvider() {
        do {
            try providers.saveDraft()
        } catch {
            errors.present(title: "Model Provider", message: error.localizedDescription)
        }
    }

    private func activateProvider(_ provider: ModelProviderProfile) {
        do {
            try providers.activateProvider(provider)
        } catch {
            errors.present(title: "Model Provider", message: error.localizedDescription)
        }
    }

    private func deleteDraftProvider() {
        do {
            try providers.deleteDraftProvider()
        } catch {
            errors.present(title: "Model Provider", message: error.localizedDescription)
        }
    }

    private var accessibilitySection: some View {
        Group {
            toggleRow(L10n.reduceMotion, L10n.reduceMotionHelp, isOn: $a11y.reduceMotion)
            rowDivider
            toggleRow(L10n.reduceTransparency, L10n.reduceTransparencyHelp,
                      isOn: $a11y.reduceTransparency)
            rowDivider
            toggleRow(L10n.increaseContrast, L10n.increaseContrastHelp, isOn: $a11y.increaseContrast)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(theme.border).frame(height: 1).padding(.vertical, 14)
    }

    /// One settings row: title + help on the left, control on the right.
    private func settingRow<Control: View>(_ title: String,
                                           _ help: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typography.label).foregroundStyle(theme.textPrimary)
                Text(help).font(Typography.footnote).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            control()
        }
    }

    /// A settings row whose control is a right-aligned switch (the Launch at
    /// Login pattern): title + help on the left, tinted switch on the right.
    private func toggleRow(_ title: String, _ help: String, isOn: Binding<Bool>) -> some View {
        settingRow(title, help) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(theme.accent)
        }
    }
}

private struct SettingsGlassSurface: ViewModifier {
    @Environment(ThemeStore.self) private var theme

    func body(content: Content) -> some View {
        content
            // Settings contains dense controls and help text, so its reading
            // surface must not transmit the photo grid underneath it.
            .background(
                theme.panel,
                in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
            )
            // Keep a restrained glass-like highlight without making the panel
            // itself translucent again.
            .overlay {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.07), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            }
    }
}

/// Inline slider + trailing live percentage (right-aligned control). Nudges its
/// width 1pt after appear so `NSSlider` draws its knob without needing a first
/// hover. Callers pass the already-computed `percent` for the trailing readout.
struct SliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let percent: Int
    /// VoiceOver label (the row's visible title); the percent is the spoken value.
    let label: String

    @Environment(ThemeStore.self) private var theme
    @State private var width: CGFloat = 179

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: range) { Text(label) }
                .labelsHidden()
                .accessibilityValue("\(percent)%")
                .frame(width: width)
                .tint(theme.accent)
            Text("\(percent)%")
                .font(Typography.control)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 42, alignment: .trailing)
        }
        .task { width = 180 }
    }
}

#Preview {
    SettingsModal(model: TransparencyModel(), ui: UIState(), a11y: AccessibilitySettings())
        .frame(width: 1000, height: 760)
        .environment(ThemeStore())
        .environment(ErrorStore())
}
