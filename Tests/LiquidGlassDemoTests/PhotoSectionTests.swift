import Testing
@testable import LiquidGlassDemo

@Suite struct PhotoSectionTests {
    @Test func countDescriptionsMatchTheActiveCategory() {
        #expect(PhotoSection.all.countDescription(1) == "1 item")
        #expect(PhotoSection.all.countDescription(12) == "12 items")
        #expect(PhotoSection.chatScreenshot.countDescription(129) == "129 chats")
        #expect(PhotoSection.posterOrMeme.countDescription(2) == "2 posters & memes")
    }

    @Test func displayAssetTypesAreConciseForCards() {
        let base = IndexedPhoto(
            id: "1",
            thumbnailPath: "",
            filePath: "",
            filename: "",
            capturedAt: nil,
            width: nil,
            height: nil,
            assetType: "ui_screenshot",
            shortCaption: "",
            model: nil,
            annotation: nil
        )
        #expect(base.displayAssetType == "Screenshot")

        let chat = IndexedPhoto(
            id: "2",
            thumbnailPath: "",
            filePath: "",
            filename: "",
            capturedAt: nil,
            width: nil,
            height: nil,
            assetType: "chat_screenshot",
            shortCaption: "",
            model: nil,
            annotation: nil
        )
        #expect(chat.displayAssetType == "Chat")
    }
}
