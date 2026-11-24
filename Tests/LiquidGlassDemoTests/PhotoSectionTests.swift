import Foundation
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

    @Test func captureDateFormatsFractionalAndWholeSecondTimestamps() {
        func photo(_ capturedAt: String?) -> IndexedPhoto {
            IndexedPhoto(id: "1", thumbnailPath: "", filePath: "", filename: "photo.jpg",
                         capturedAt: capturedAt, width: nil, height: nil, assetType: "photo",
                         shortCaption: "", model: nil, annotation: nil)
        }
        let date = Date(timeIntervalSince1970: 1_791_871_065)
        let expected = date.formatted(date: .abbreviated, time: .shortened)
        #expect(photo("2026-10-13T05:57:45.287Z").displayCapturedAt == expected)
        #expect(photo("2026-10-13T05:57:45Z").displayCapturedAt == expected)
        #expect(photo("unknown").displayCapturedAt == "unknown")
        #expect(photo(nil).displayCapturedAt == nil)
    }
}
