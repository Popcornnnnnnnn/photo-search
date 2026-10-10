import Foundation

enum PhotoSection: String, CaseIterable, Identifiable, Sendable, Codable {
    case all
    case photo
    case video
    case uiScreenshot
    case chatScreenshot
    case document
    case posterOrMeme

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All indexed"
        case .photo: "Photos"
        case .video: String(localized: "Videos", bundle: .module)
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
        case .video: "video"
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
        case .video: "video"
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
        case .video:
            return count == 1
                ? String(localized: "\(count.formatted()) video", bundle: .module)
                : String(localized: "\(count.formatted()) videos", bundle: .module)
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

enum PhotoTimeFilter: Hashable, Sendable {
    case all, last30Days, thisYear, lastYear
    case custom(start: Date, end: Date)
    static let presets: [Self] = [.all, .last30Days, .thisYear, .lastYear]
    var title: String {
        switch self {
        case .all: String(localized: "Any date", bundle: .module)
        case .last30Days: String(localized: "Last 30 days", bundle: .module)
        case .thisYear: String(localized: "This year", bundle: .module)
        case .lastYear: String(localized: "Last year", bundle: .module)
        case .custom(let start, let end):
            start.formatted(date: .abbreviated, time: .omitted) + " – " + end.formatted(date: .abbreviated, time: .omitted)
        }
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .all: return nil
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return nil }
            return DateInterval(start: start, end: now)
        case .thisYear: return calendar.dateInterval(of: .year, for: now)
        case .lastYear:
            guard let previous = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .year, for: previous)
        case .custom(let start, let end):
            let firstDay = calendar.startOfDay(for: min(start, end))
            let lastDay = calendar.startOfDay(for: max(start, end))
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
            return DateInterval(start: firstDay, end: nextDay)
        }
    }
}

struct PhotoMatchEvidence: Hashable, Sendable {
    let textMatched: Bool
    let visualMatched: Bool
    var isVideo = false

    var label: String {
        switch (textMatched, visualMatched) {
        case (true, true): String(localized: "Text + semantic match", bundle: .module)
        case (true, false): String(localized: "Text match", bundle: .module)
        case (false, true): isVideo
            ? String(localized: "Video description match", bundle: .module)
            : String(localized: "Visual match", bundle: .module)
        default: ""
        }
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

    var durationSeconds: Double? = nil
    var matchEvidence: PhotoMatchEvidence? = nil

    var isVideo: Bool { assetType == "video" }

    var displayDuration: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds >= 0 else { return nil }
        let seconds = Int(durationSeconds.rounded())
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func videoDuration(from metadata: String) -> Double? {
        guard let data = metadata.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["duration_seconds"] as? Double
    }

    var displayAssetType: String {
        switch assetType {
        case "video": String(localized: "Video", bundle: .module)
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

struct PhotoLibraryStats: Decodable, Sendable {
    let total: Int
    let indexed: Int
    let failed: Int

    static let empty = PhotoLibraryStats(total: 0, indexed: 0, failed: 0)
}
