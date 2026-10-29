import UIKit

struct WebShortcut: Equatable {
    var title: String
    var url: String
}

enum SearchEngine: Int, CaseIterable {
    case google, naver, bing, duckDuckGo

    var name: String {
        switch self {
        case .google: return "Google"
        case .naver: return "네이버"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        }
    }

    func url(for query: String) -> URL? {
        let (base, parameter): (String, String)
        switch self {
        case .google: (base, parameter) = ("https://www.google.com/search", "q")
        case .naver: (base, parameter) = ("https://search.naver.com/search.naver", "query")
        case .bing: (base, parameter) = ("https://www.bing.com/search", "q")
        case .duckDuckGo: (base, parameter) = ("https://duckduckgo.com/", "q")
        }
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = [URLQueryItem(name: parameter, value: query)]
        // URLComponents leaves "+" alone, but search engines read it as a space.
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = encoded
        return components.url
    }
}

/// UserDefaults-backed preferences. Every change posts `Settings.didChange`.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("PocketDeskSettingsDidChange")

    private let defaults = UserDefaults.standard

    private func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    private func store(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: self, userInfo: ["key": key])
    }

    /// Trackpad / mouse speed multiplier (0.4 … 3).
    var pointerSpeed: Double {
        get { value("pointerSpeed", 1.0) }
        set { store(newValue, "pointerSpeed") }
    }

    var naturalScrolling: Bool {
        get { value("naturalScrolling", true) }
        set { store(newValue, "naturalScrolling") }
    }

    var haptics: Bool {
        get { value("haptics", true) }
        set { store(newValue, "haptics") }
    }

    /// Desktop UI scale. 0 means automatic (based on the display resolution).
    var uiScale: Double {
        get { value("uiScale", 0.0) }
        set { store(newValue, "uiScale") }
    }

    /// Index into `Wallpaper.presets`, or -1 for the custom photo.
    var wallpaperIndex: Int {
        get { value("wallpaperIndex", 0) }
        set { store(newValue, "wallpaperIndex") }
    }

    var desktopWebsites: Bool {
        get { value("desktopWebsites", true) }
        set { store(newValue, "desktopWebsites") }
    }

    var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: value("searchEngine", 0)) ?? .google }
        set { store(newValue.rawValue, "searchEngine") }
    }

    var homePage: String {
        get { value("homePage", "https://www.google.com") }
        set { store(newValue, "homePage") }
    }

    var hasShownHelp: Bool {
        get { value("hasShownHelp", false) }
        set { defaults.set(newValue, forKey: "hasShownHelp") }
    }

    var shortcuts: [WebShortcut] {
        get {
            guard let raw = defaults.array(forKey: "shortcuts") as? [[String: String]] else {
                return Settings.defaultShortcuts
            }
            return raw.compactMap { entry in
                guard let title = entry["title"], let url = entry["url"] else { return nil }
                return WebShortcut(title: title, url: url)
            }
        }
        set {
            store(newValue.map { ["title": $0.title, "url": $0.url] }, "shortcuts")
        }
    }

    static let defaultShortcuts: [WebShortcut] = [
        WebShortcut(title: "YouTube", url: "https://www.youtube.com"),
        WebShortcut(title: "네이버", url: "https://www.naver.com"),
        WebShortcut(title: "Google", url: "https://www.google.com"),
        WebShortcut(title: "Gmail", url: "https://mail.google.com"),
        WebShortcut(title: "Google 문서", url: "https://docs.google.com"),
    ]

    /// Turns what the user typed into a URL: either a web address or a search.
    func url(fromUserInput input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "file://", "about:", "data:"] where lower.hasPrefix(scheme) {
            if let url = URL(string: text) { return url }
        }
        let hostPart = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        let hostOnly = String(hostPart.split(separator: ":").first ?? "")
        let labels = hostOnly.split(separator: ".")
        let topLevel = labels.last.map(String.init) ?? ""
        let isIPAddress = labels.count == 4 && labels.allSatisfy { Int($0) != nil }
        let looksLikeHost = !text.contains(" ") && (
            isIPAddress || hostOnly == "localhost"
                || (labels.count >= 2 && topLevel.count >= 2 && topLevel.allSatisfy { $0.isLetter })
        )
        if looksLikeHost, let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        return searchEngine.url(for: text)
    }
}
