import Foundation
import Testing
@testable import LiquidGlassDemo

@Suite struct DeepLinkTests {
    @Test func parsesThemeLink() {
        #expect(DeepLink(url: URL(string: "photosearch://theme/ember")!) == .theme(.ember))
        #expect(DeepLink(url: URL(string: "photosearch://theme/cyberpunk")!) == .theme(.cyberpunk))
    }

    @Test func rejectsUnknownTheme() {
        #expect(DeepLink(url: URL(string: "photosearch://theme/plaid")!) == nil)
    }

    @Test func rejectsMissingThemeID() {
        #expect(DeepLink(url: URL(string: "photosearch://theme")!) == nil)
    }

    @Test func rejectsUnknownHost() {
        #expect(DeepLink(url: URL(string: "photosearch://settings")!) == nil)
    }

    @Test func rejectsWrongScheme() {
        #expect(DeepLink(url: URL(string: "https://example.com/theme/ember")!) == nil)
    }

    @Test func parsesSearchDeepLinkAndPresets() {
        let english = DeepLink(url: URL(string: "photosearch://search?q=coffee%20cup&section=video&time=last30Days")!)
        #expect(english == .search(query: "coffee cup", section: .video, timeFilter: .last30Days))

        let chinese = DeepLink(url: URL(string: "photosearch://search?q=%E9%BB%91%E7%8C%AB&section=ui_screenshot&time=last_year")!)
        #expect(chinese == .search(query: "黑猫", section: .uiScreenshot, timeFilter: .lastYear))

        let browse = DeepLink(url: URL(string: "photosearch://search?section=photos&time=this_year")!)
        #expect(browse == .search(query: "", section: .photo, timeFilter: .thisYear))
    }

    @Test func parsesAndValidatesAssetDeepLink() {
        #expect(DeepLink(url: URL(string: "photosearch://asset/photos-abc123")!) == .asset(id: "photos-abc123"))
        #expect(DeepLink(url: URL(string: "photosearch://asset?id=file-xyz789")!) == .asset(id: "file-xyz789"))
        #expect(DeepLink(url: URL(string: "photosearch://asset")!) == nil)
        #expect(DeepLink(url: URL(string: "photosearch://asset/%20%20")!) == nil)
    }
}
