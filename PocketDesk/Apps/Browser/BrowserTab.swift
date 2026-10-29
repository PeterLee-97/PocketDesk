import UIKit
import WebKit

enum JS {
    /// Encodes a Swift string as a JavaScript string literal.
    static func string(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else { return "''" }
        return String(json.dropFirst().dropLast())
    }
}

/// Routes `window.webkit.messageHandlers.pocketdesk` messages to the tab that sent them.
final class BrowserMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = BrowserMessageRouter()
    static let name = "pocketdesk"
    private let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    func register(_ tab: BrowserTab) {
        tabs.setObject(tab, forKey: tab.webView)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = tabs.object(forKey: webView),
              let body = message.body as? [String: Any] else { return }
        tab.owner?.handleScriptMessage(body, from: tab)
    }
}

enum BrowserEnvironment {
    static let world = WKContentWorld.world(name: "PocketDesk")

    /// One controller shared by every web view, so popups (which inherit their opener's
    /// configuration) never register the message handler twice.
    static let contentController: WKUserContentController = {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: BrowserScripts.viewport, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: BrowserScripts.media, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.addUserScript(WKUserScript(source: BrowserScripts.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: BrowserScripts.fullscreen, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.add(BrowserMessageRouter.shared, contentWorld: .page, name: BrowserMessageRouter.name)
        return controller
    }()

    static var contentMode: WKWebpagePreferences.ContentMode {
        Settings.shared.desktopWebsites ? .desktop : .mobile
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()
        // Without this, iPhone WebKit plays every video in the native fullscreen player.
        configuration.allowsInlineMediaPlayback = true
        // Synthetic clicks aren't "user gestures", so don't require one for playback.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.preferredContentMode = contentMode
        configuration.dataDetectorTypes = []
        return configuration
    }
}

/// Keyboard input for the page: forwarded to the injected bridge.
final class WebKeyTarget: KeyInputTarget {
    weak var tab: BrowserTab?

    var acceptsTextInput: Bool { tab?.isEditableFocused ?? false }
    var keyboardType: UIKeyboardType { .default }
    var inputDescription: String { acceptsTextInput ? "웹페이지 입력란" : "웹페이지" }

    func insertText(_ text: String) {
        tab?.bridge("__pd.text(\(JS.string(text)))") { [weak self] value in self?.update(from: value) }
    }

    func deleteBackward() {
        send(SpecialKey.backspace.rawValue, modifiers: [])
    }

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        send(key.rawValue, modifiers: modifiers)
    }

    private func send(_ key: String, modifiers: KeyModifiers) {
        tab?.bridge("__pd.key(\(JS.string(key)),\(modifiers.jsObject))") { [weak self] value in self?.update(from: value) }
    }

    func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey, let tab else { return false }
        switch key {
        case "c", "x":
            tab.bridge("__pd.copy(\(key == "x"))") { value in
                if let text = value as? String, !text.isEmpty { UIPasteboard.general.string = text }
            }
        case "v":
            if let text = UIPasteboard.general.string, !text.isEmpty { insertText(text) }
        default:
            tab.bridge("__pd.shortcut(\(JS.string(key)),\(modifiers.jsObject))")
        }
        return true
    }

    func update(from value: Any?) {
        guard let info = value as? [String: Any], let editable = info["editable"] as? Bool, let tab else { return }
        if tab.isEditableFocused != editable {
            tab.isEditableFocused = editable
            if DeskSession.shared.desktop?.keyFocus === self {
                DeskSession.shared.desktop?.keyFocusStateChanged()
            }
        }
    }
}

final class BrowserTab: NSObject {
    let webView: WKWebView
    weak var owner: BrowserContent?
    let keyTarget = WebKeyTarget()
    var isEditableFocused = false
    var errorMessage: String?
    private(set) var lastRequestedURL: URL?
    var zoom: CGFloat = 1 { didSet { applyZoom() } }
    private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, owner: BrowserContent) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.owner = owner
        super.init()
        keyTarget.tab = self
        // The external display never delivers touches; all input arrives through the bridge.
        webView.isUserInteractionEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .white
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        webView.navigationDelegate = owner
        webView.uiDelegate = owner
        applyZoom()
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.changed() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.changed() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.changed() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.changed() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.changed() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.changed() },
        ]
        BrowserMessageRouter.shared.register(self)
    }

    private func changed() {
        owner?.tabDidChange(self)
    }

    func applyZoom() {
        webView.pageZoom = zoom
    }

    var displayTitle: String {
        if let title = webView.title, !title.isEmpty { return title }
        if let host = webView.url?.host, !host.isEmpty { return host }
        if let url = webView.url, url.isFileURL { return url.lastPathComponent }
        return "새 탭"
    }

    func load(_ url: URL) {
        errorMessage = nil
        lastRequestedURL = url
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func retry() {
        errorMessage = nil
        if webView.url != nil {
            webView.reload()
        } else if let url = lastRequestedURL {
            load(url)
        }
    }

    /// Runs `script` in the bridge's isolated world. (Calls the Objective-C method directly rather
    /// than the Swift `Result` overlay, which lives in a separate library on older SDKs.)
    func bridge(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView.__evaluateJavaScript("window.__pd ? (\(script)) : null", inFrame: nil, in: BrowserEnvironment.world) { value, error in
            completion?(error == nil ? value : nil)
        }
    }

    /// Runs `script` in the page's own world.
    func page(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func close() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}

final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    private var destinations: [ObjectIdentifier: URL] = [:]

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let url = FileStore.uniqueURL(in: FileStore.downloads, preferredName: suggestedFilename)
        destinations[ObjectIdentifier(download)] = url
        completionHandler(url)
        DeskSession.shared.desktop?.showToast("다운로드 중: \(url.lastPathComponent)", symbol: "arrow.down.circle")
    }

    func downloadDidFinish(_ download: WKDownload) {
        let url = destinations.removeValue(forKey: ObjectIdentifier(download))
        FileStore.notifyChange()
        DeskSession.shared.desktop?.showToast("다운로드 완료: \(url?.lastPathComponent ?? "") (내 파일 › 다운로드)", symbol: "checkmark.circle")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        DeskSession.shared.desktop?.showToast("다운로드 실패: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
    }
}
