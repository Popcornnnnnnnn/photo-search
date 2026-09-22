import Testing
import Foundation
@testable import LiquidGlassDemo

@Suite struct SettingsSectionTests {
    @Test func everySectionHasIconTitleAndSubtitle() {
        #expect(SettingsSection.allCases.count == 4)
        for section in SettingsSection.allCases {
            #expect(!section.icon.isEmpty)
            #expect(!section.title.isEmpty)
            #expect(!section.subtitle.isEmpty)
        }
    }

    /// The cog/⌘, always lands on General: closing the modal resets the section,
    /// so only an explicit deep link (the card's Customize) opens another page.
    @MainActor
    @Test func closingSettingsResetsToGeneral() {
        let ui = UIState()
        ui.settingsSection = .accessibility
        ui.showSettings = true
        ui.showSettings = false
        #expect(ui.settingsSection == .general)
    }
}

@Suite struct ModelProviderSettingsTests {
    @MainActor
    @Test func defaultsToPrivateQwenProvider() {
        let settings = ModelProviderSettings(configuration: .default)
        #expect(settings.activeProvider?.id == "qwen-4090")
        #expect(settings.activeProvider?.requiresTailscale == true)
        #expect(settings.configuration.reprocessExisting == false)
    }

    @MainActor
    @Test func addingProviderDoesNotReplaceExistingProvider() {
        let settings = ModelProviderSettings(configuration: .default)
        settings.beginAddingProvider()
        #expect(settings.configuration.providers.count == 1)
        #expect(settings.configuration.activeProviderID == "qwen-4090")
        #expect(settings.draftProvider?.id != "qwen-4090")
        settings.cancelEditing()
        #expect(settings.configuration.providers.count == 1)
    }

    @MainActor
    @Test func editingUsesDetachedDraftUntilSaved() {
        let settings = ModelProviderSettings(configuration: .default)
        settings.beginEditingProvider(.qwen4090)
        settings.draftProvider?.name = "Changed Draft"
        #expect(settings.configuration.providers[0].name == "Qwen 4090")
    }

    @Test func providerConfigurationRoundTripsSnakeCaseFile() throws {
        let data = try JSONEncoder().encode(ModelProviderFile.default)
        let decoded = try JSONDecoder().decode(ModelProviderFile.self, from: data)
        #expect(decoded == .default)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("active_provider_id"))
        #expect(json.contains("base_url"))
    }
}
