import Foundation

enum PhotoSection: String, CaseIterable, Identifiable, Sendable {
    case all
    case photo
    case uiScreenshot
    case chatScreenshot
    case document
    case posterOrMeme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All indexed"
        case .photo: "Photos"
        case .uiScreenshot: "Screenshots"
        case .chatScreenshot: "Chats"
        case .document: "Documents"
        case .posterOrMeme: "Posters & memes"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "sparkles.rectangle.stack"
        case .photo: "photo.on.rectangle.angled"
        case .uiScreenshot: "macwindow"
        case .chatScreenshot: "message"
        case .document: "doc.text"
        case .posterOrMeme: "rectangle.on.rectangle"
        }
    }

    var assetType: String? {
        switch self {
        case .all: nil
        case .photo: "photo"
        case .uiScreenshot: "ui_screenshot"
        case .chatScreenshot: "chat_screenshot"
        case .document: "document"
        case .posterOrMeme: "poster_or_meme"
        }
    }

    func countDescription(_ count: Int) -> String {
        let singular: String
        let plural: String
        switch self {
        case .all:
            singular = "item"
            plural = "items"
        case .photo:
            singular = "photo"
            plural = "photos"
        case .uiScreenshot:
            singular = "screenshot"
            plural = "screenshots"
        case .chatScreenshot:
            singular = "chat"
            plural = "chats"
        case .document:
            singular = "document"
            plural = "documents"
        case .posterOrMeme:
            singular = "poster or meme"
            plural = "posters & memes"
        }
        return "\(count.formatted()) \(count == 1 ? singular : plural)"
    }
}

struct PhotoAnnotation: Decodable, Hashable, Sendable {
    var assetType: String?
    var shortCaption: String?
    var detailedDescription: String?
    var entities: [String]?
    var actions: [String]?
    var scene: String?
    var topics: [String]?
    var timeClues: [String]?
    var locationClues: [String]?
    var observedFacts: [String]?
    var inferences: [String]?
    var uncertainties: [String]?
    var searchTerms: [String]?

    static func decode(_ json: String?) -> PhotoAnnotation? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Self.self, from: data)
    }
}

struct IndexedPhoto: Identifiable, Hashable, Sendable {
    let id: String
    let thumbnailPath: String
    let filePath: String
    let filename: String
    let capturedAt: String?
    let width: Int?
    let height: Int?
    let assetType: String
    let shortCaption: String
    let model: String?
    let annotation: PhotoAnnotation?

    var displayAssetType: String {
        switch assetType {
        case "ui_screenshot": "Screenshot"
        case "chat_screenshot": "Chat"
        case "poster_or_meme": "Poster / Meme"
        default: assetType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var displayCapturedAt: String? {
        guard let capturedAt else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: capturedAt) else { return capturedAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct PhotoLibraryStats: Sendable {
    let total: Int
    let indexed: Int
    let failed: Int

    static let empty = PhotoLibraryStats(total: 0, indexed: 0, failed: 0)
}
