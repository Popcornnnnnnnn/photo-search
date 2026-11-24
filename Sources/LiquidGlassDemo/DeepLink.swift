import Foundation

/// A deep link into the app (`photosearch://...`). Parsed as pure data so
/// routing stays unit-testable; `ContentView` handles incoming URLs via
/// `.onOpenURL`. The scheme is registered only in the packaged app's
/// Info.plist (`url_scheme` in app.yml), so links do nothing under `swift run`.
enum DeepLink: Equatable, Sendable {
    /// `photosearch://theme/<id>` — switch the active theme.
    case theme(ThemeID)
    /// `photosearch://search?q=...&section=...&time=...` — open search or filtered library.
    case search(query: String, section: PhotoSection, timeFilter: PhotoTimeFilter)
    /// `photosearch://asset/<id>` — open a specific photo or video in the viewer.
    case asset(id: String)

    /// The URL scheme the packaged app registers (keep in sync with app.yml).
    static let scheme = "photosearch"

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        switch host {
        case "theme":
            // photosearch://theme/ember → pathComponents ["/", "ember"]
            guard let raw = url.pathComponents.dropFirst().first,
                  let id = ThemeID(rawValue: raw) else { return nil }
            self = .theme(id)
        case "search":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []
            let query = items.first(where: { $0.name == "q" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let section = PhotoSection.fromBridgeKey(items.first(where: { $0.name == "section" })?.value)
            let timeFilter = PhotoTimeFilter.fromBridgeKey(items.first(where: { $0.name == "time" })?.value)
            self = .search(query: query, section: section, timeFilter: timeFilter)
        case "asset":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let pathID = url.pathComponents.dropFirst().first(where: { !$0.isEmpty && $0 != "/" })
            let queryID = components?.queryItems?.first(where: { $0.name == "id" })?.value
            guard let rawID = (pathID ?? queryID)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawID.isEmpty,
                  rawID.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            self = .asset(id: rawID)
        default:
            return nil
        }
    }
}
