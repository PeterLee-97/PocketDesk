import UIKit
import WebKit

/// Receives virtual-pointer events over the web page and hands them to the browser.
final class WebPointerView: UIView, PointerTarget, ScrollTarget, HoverTarget, CursorProvider, ZoomTarget {
    weak var browser: BrowserContent?

    func pointerDown(_ event: PointerEvent) -> Bool { browser?.webPointerDown(event) ?? false }
    func pointerDragged(_ event: PointerEvent) { browser?.webPointerDragged(event) }
    func pointerUp(_ event: PointerEvent) { browser?.webPointerUp(event) }
    func scroll(by delta: CGPoint, event: PointerEvent) -> Bool { browser?.webScroll(by: delta, event: event) ?? false }
    func pointerMoved(_ event: PointerEvent) { browser?.webHover(event) }
    func pointerExited() { browser?.webPointerExited() }
    func cursor(at point: CGPoint) -> CursorKind? { browser?.webCursor ?? .arrow }
    func zoom(by factor: CGFloat, event: PointerEvent) { browser?.pinchZoom(by: factor) }
    func smartZoom(event: PointerEvent) { browser?.smartZoom() }
}

final class BrowserErrorView: UIView {
    let retryButton = DeskButton(symbol: "arrow.clockwise", title: "다시 시도")
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()

    var message: String? {
        didSet {
            messageLabel.text = message
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.windowBackground
        iconView.tintColor = Theme.secondaryText
        iconView.contentMode = .center
        titleLabel.text = "페이지를 열 수 없습니다"
        titleLabel.textColor = Theme.text
        titleLabel.textAlignment = .center
        messageLabel.textColor = Theme.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        retryButton.normalBackground = UIColor(white: 1, alpha: 0.1)
        retryButton.horizontalPadding = 16
        for view in [iconView, titleLabel, messageLabel, retryButton] as [UIView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        iconView.image = Theme.symbol("wifi.exclamationmark", size: 40, weight: .light)
        titleLabel.font = Theme.font(18, .semibold)
        messageLabel.font = Theme.font(13)
        let width = min(bounds.width - Theme.s(40), Theme.s(520))
        let messageHeight = ceil(messageLabel.sizeThatFits(CGSize(width: width, height: 400)).height)
        var y = bounds.height * 0.28
        iconView.frame = CGRect(x: 0, y: y, width: bounds.width, height: Theme.s(50))
        y += Theme.s(62)
        titleLabel.frame = CGRect(x: (bounds.width - width) / 2, y: y, width: width, height: Theme.s(26))
        y += Theme.s(34)
        messageLabel.frame = CGRect(x: (bounds.width - width) / 2, y: y, width: width, height: messageHeight)
        y += messageHeight + Theme.s(18)
        let buttonWidth = retryButton.preferredWidth()
        retryButton.frame = CGRect(x: (bounds.width - buttonWidth) / 2, y: y, width: buttonWidth, height: Theme.s(32))
    }
}

/// Web browser with tabs. Pages are real WKWebViews; the virtual mouse and keyboard reach them
/// through the injected bridge (see `BrowserScripts`).
final class BrowserContent: AppContentView, WKNavigationDelegate, WKUIDelegate {
    private let tabStrip = BrowserTabStrip()
    private let toolbar = UIView()
    private let backButton = DeskButton(symbol: "chevron.left")
    private let forwardButton = DeskButton(symbol: "chevron.right")
    private let reloadButton = DeskButton(symbol: "arrow.clockwise")
    private let homeButton = DeskButton(symbol: "house")
    let addressField = DeskTextField(placeholder: "검색어 또는 웹 주소를 입력하세요")
    private let pinButton = DeskButton(symbol: "plus.rectangle.on.rectangle")
    private let menuButton = DeskButton(symbol: "ellipsis")
    private let progressBar = UIView()
    private let webArea = WebPointerView()
    private let errorView = BrowserErrorView()

    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedIndex = 0
    var currentTab: BrowserTab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    private(set) var isFullscreen = false
    private var focusAddressOnActivate = false

    fileprivate var webCursor: CursorKind = .arrow
    private var lastHoverTime: CFTimeInterval = 0
    private var hoverToken = 0
    private var lastDragTime: CFTimeInterval = 0

    private enum ScrollMode { case unknown, pending, native, page }
    private var scrollMode: ScrollMode = .unknown
    private var lastScrollTime: CFTimeInterval = 0
    private var lastScrollPoint: CGPoint = .zero
    private var pendingScroll: CGPoint = .zero

    private var homeURL: URL {
        URL(string: Settings.shared.homePage) ?? URL(string: "https://www.google.com")!
    }

    init(url: URL?, configuration: WKWebViewConfiguration?) {
        super.init(frame: .zero)
        backgroundColor = Theme.windowBackground
        tabStrip.backgroundColor = UIColor(hex: 0x17181B)
        toolbar.backgroundColor = Theme.panel
        progressBar.backgroundColor = Theme.accent
        progressBar.isUserInteractionEnabled = false
        webArea.browser = self
        webArea.backgroundColor = .white
        webArea.clipsToBounds = true
        errorView.isHidden = true
        errorView.retryButton.onTap = { [weak self] in
            self?.currentTab?.retry()
            self?.updateChrome()
        }

        addSubview(webArea)
        webArea.addSubview(errorView)
        addSubview(tabStrip)
        addSubview(toolbar)
        toolbar.addSubview(progressBar)
        for button in [backButton, forwardButton, reloadButton, homeButton, pinButton, menuButton] {
            button.symbolSize = 14
            toolbar.addSubview(button)
        }
        toolbar.addSubview(addressField)

        tabStrip.onSelect = { [weak self] index in self?.selectTab(index) }
        tabStrip.onClose = { [weak self] index in self?.closeTab(index) }
        tabStrip.onNewTab = { [weak self] in self?.newTab() }
        backButton.onTap = { [weak self] in self?.currentTab?.webView.goBack() }
        forwardButton.onTap = { [weak self] in self?.currentTab?.webView.goForward() }
        reloadButton.onTap = { [weak self] in
            guard let web = self?.currentTab?.webView else { return }
            if web.isLoading { web.stopLoading() } else { self?.currentTab?.retry() }
        }
        homeButton.onTap = { [weak self] in
            guard let self else { return }
            self.currentTab?.load(self.homeURL)
        }
        pinButton.onTap = { [weak self] in self?.addCurrentPageToDesktop() }
        menuButton.onTap = { [weak self] in self?.showBrowserMenu() }

        addressField.fontSize = 13.5
        addressField.selectsAllOnFocus = true
        addressField.keyboardType = .webSearch
        addressField.inputDescription = "주소창"
        addressField.onSubmit = { [weak self] text in self?.navigate(text) }
        addressField.onEscape = { [weak self] in self?.cancelAddressEditing() }

        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)

        let tab = addTab(configuration: configuration ?? BrowserEnvironment.makeConfiguration(), select: true)
        if let url {
            tab.load(url)
        } else if configuration == nil {
            tab.load(homeURL)
            focusAddressOnActivate = true
        }
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? {
        focusAddressOnActivate ? addressField : currentTab?.keyTarget
    }

    @objc private func themeChanged() {
        tabs.forEach { $0.applyZoom() }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        tabStrip.isHidden = isFullscreen
        toolbar.isHidden = isFullscreen
        if isFullscreen {
            webArea.frame = bounds
        } else {
            let stripHeight = Theme.s(34)
            let barHeight = Theme.s(42)
            tabStrip.frame = CGRect(x: 0, y: 0, width: width, height: stripHeight)
            toolbar.frame = CGRect(x: 0, y: stripHeight, width: width, height: barHeight)
            let size = Theme.s(30)
            let y = (barHeight - size) / 2
            var x = Theme.s(8)
            for button in [backButton, forwardButton, reloadButton, homeButton] {
                button.frame = CGRect(x: x, y: y, width: size, height: size)
                x += size + Theme.s(2)
            }
            var right = width - Theme.s(8)
            for button in [menuButton, pinButton] {
                right -= size
                button.frame = CGRect(x: right, y: y, width: size, height: size)
                right -= Theme.s(2)
            }
            addressField.frame = CGRect(x: x + Theme.s(6), y: y, width: max(Theme.s(80), right - x - Theme.s(12)), height: size)
            layoutProgress()
            webArea.frame = CGRect(x: 0, y: toolbar.frame.maxY, width: width, height: max(0, bounds.height - toolbar.frame.maxY))
        }
        currentTab?.webView.frame = webArea.bounds
        errorView.frame = webArea.bounds
    }

    private func layoutProgress() {
        guard let web = currentTab?.webView else { return }
        progressBar.isHidden = !web.isLoading
        let height = max(2, Theme.s(2))
        progressBar.frame = CGRect(x: 0, y: toolbar.bounds.height - height, width: toolbar.bounds.width * CGFloat(max(0.05, web.estimatedProgress)), height: height)
    }

    // MARK: Tabs

    @discardableResult
    private func addTab(configuration: WKWebViewConfiguration, select: Bool, at index: Int? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration, owner: self)
        let position = min(index ?? tabs.count, tabs.count)
        tabs.insert(tab, at: position)
        if select {
            selectTab(position)
        } else {
            if position <= selectedIndex && tabs.count > 1 { selectedIndex += 1 }
            refreshTabStrip()
        }
        return tab
    }

    func openTab(url: URL, select: Bool = true) {
        let tab = addTab(configuration: BrowserEnvironment.makeConfiguration(), select: select, at: selectedIndex + 1)
        tab.load(url)
        if select {
            focusAddressOnActivate = false
            desktop?.setKeyFocus(tab.keyTarget)
        }
    }

    private func newTab() {
        openTab(url: homeURL)
        focusAddressBar()
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let previous = currentTab
        let hadFocus = previous.map { desktop?.keyFocus === $0.keyTarget } ?? false
        let tab = tabs[index]
        if let previous, previous !== tab {
            previous.bridge("__pd.leave()")
            previous.webView.removeFromSuperview()
        }
        selectedIndex = index
        if tab.webView.superview !== webArea {
            webArea.insertSubview(tab.webView, at: 0)
        }
        tab.webView.frame = webArea.bounds
        scrollMode = .unknown
        updateChrome()
        if hadFocus { desktop?.setKeyFocus(tab.keyTarget) }
    }

    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard tabs.count > 1 else {
            if let window = deskWindow { desktop?.close(window) }
            return
        }
        let tab = tabs[index]
        let refocus = desktop?.keyFocus === tab.keyTarget || desktop?.keyFocus === addressField
        tab.close()
        tabs.remove(at: index)
        if index == selectedIndex {
            let next = min(index, tabs.count - 1)
            selectedIndex = next
            webArea.insertSubview(tabs[next].webView, at: 0)
            tabs[next].webView.frame = webArea.bounds
        } else if index < selectedIndex {
            selectedIndex -= 1
        }
        scrollMode = .unknown
        updateChrome()
        if refocus, let current = currentTab { desktop?.setKeyFocus(current.keyTarget) }
    }

    func tabDidChange(_ tab: BrowserTab) {
        if tab === currentTab {
            updateChrome()
        } else {
            refreshTabStrip()
        }
    }

    private func refreshTabStrip() {
        tabStrip.update(titles: tabs.map { $0.displayTitle }, loading: tabs.map { $0.webView.isLoading }, selected: selectedIndex)
    }

    private func updateChrome() {
        refreshTabStrip()
        guard let tab = currentTab else { return }
        let web = tab.webView
        backButton.isEnabled = web.canGoBack
        forwardButton.isEnabled = web.canGoForward
        reloadButton.symbolName = web.isLoading ? "xmark" : "arrow.clockwise"
        if !addressField.hasKeyFocus {
            addressField.text = displayAddress(web.url ?? tab.lastRequestedURL)
        }
        title = tab.displayTitle
        errorView.isHidden = tab.errorMessage == nil
        errorView.message = tab.errorMessage
        layoutProgress()
    }

    private func displayAddress(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.isFileURL ? url.lastPathComponent : url.absoluteString
    }

    // MARK: Navigation

    private func navigate(_ text: String) {
        guard let tab = currentTab, let url = Settings.shared.url(fromUserInput: text) else { return }
        tab.load(url)
        focusAddressOnActivate = false
        desktop?.setKeyFocus(tab.keyTarget)
        updateChrome()
    }

    private func cancelAddressEditing() {
        addressField.text = displayAddress(currentTab?.webView.url)
        if let tab = currentTab { desktop?.setKeyFocus(tab.keyTarget) }
    }

    func focusAddressBar() {
        desktop?.setKeyFocus(addressField)
        addressField.selectAll()
    }

    private func zoom(by delta: CGFloat) {
        guard let tab = currentTab else { return }
        tab.zoom = min(max((tab.zoom + delta) * 10, 3), 30).rounded() / 10
        desktop?.showToast("페이지 확대/축소: \(Int((tab.zoom * 100).rounded()))%", symbol: "plus.magnifyingglass")
    }

    func pinchZoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0, let tab = currentTab else { return }
        tab.zoom = min(max(tab.zoom * factor, 0.3), 3)
    }

    func smartZoom() {
        guard let tab = currentTab else { return }
        tab.zoom = abs(tab.zoom - 1) < 0.05 ? 1.5 : 1
    }

    func swipePage(horizontal: CGFloat) {
        guard let web = currentTab?.webView,
              web.scrollView.contentSize.width <= web.bounds.width + 8 else { return }
        if horizontal > 0 { web.goBack() } else { web.goForward() }
    }

    private func addCurrentPageToDesktop() {
        guard let tab = currentTab, let url = tab.webView.url, !url.isFileURL else { return }
        let title = tab.displayTitle
        let short = title.count > 16 ? String(title.prefix(16)) : title
        desktop?.addShortcut(WebShortcut(title: short, url: url.absoluteString))
    }

    private func showBrowserMenu() {
        guard let desktop else { return }
        let zoomPercent = Int(((currentTab?.zoom ?? 1) * 100).rounded())
        let items: [MenuItem] = [
            MenuItem(title: "새 탭", symbol: "plus.square.on.square", shortcut: "⌘T") { [weak self] in self?.newTab() },
            MenuItem(title: "새 창", symbol: "macwindow.badge.plus", shortcut: "⌘N") { desktop.open(.browser) },
            .separator,
            MenuItem(title: "확대", symbol: "plus.magnifyingglass", shortcut: "⌘+") { [weak self] in self?.zoom(by: 0.1) },
            MenuItem(title: "축소", symbol: "minus.magnifyingglass", shortcut: "⌘−") { [weak self] in self?.zoom(by: -0.1) },
            MenuItem(title: "실제 크기 (현재 \(zoomPercent)%)", symbol: "1.magnifyingglass", shortcut: "⌘0") { [weak self] in self?.currentTab?.zoom = 1 },
            .separator,
            MenuItem(title: "재생 중인 영상 소리 켜기", symbol: "speaker.wave.2.fill") { [weak self] in
                PlaybackAudio.shared.activate()
                self?.currentTab?.page("window.__pdEnableSound && window.__pdEnableSound()")
            },
            MenuItem(title: "데스크톱 웹사이트", symbol: "desktopcomputer", isChecked: Settings.shared.desktopWebsites) { [weak self] in
                Settings.shared.desktopWebsites.toggle()
                self?.currentTab?.webView.reload()
            },
            MenuItem(title: "바탕화면에 바로가기 추가", symbol: "plus.rectangle.on.rectangle", shortcut: "⌘D") { [weak self] in self?.addCurrentPageToDesktop() },
            MenuItem(title: "다운로드 폴더 열기", symbol: "arrow.down.circle") { desktop.open(.files, fileURL: FileStore.downloads) },
        ]
        let anchor = menuButton.convert(CGPoint(x: menuButton.bounds.maxX, y: menuButton.bounds.maxY), to: desktop.rootView)
        desktop.showContextMenu(items, at: CGPoint(x: anchor.x - Theme.s(200), y: anchor.y))
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "t":
            newTab()
        case "w":
            closeTab(selectedIndex)
        case "l":
            focusAddressBar()
        case "r":
            currentTab?.retry()
        case "[":
            currentTab?.webView.goBack()
        case "]":
            currentTab?.webView.goForward()
        case "=", "+":
            zoom(by: 0.1)
        case "-":
            zoom(by: -0.1)
        case "0":
            currentTab?.zoom = 1
        case "d":
            addCurrentPageToDesktop()
        default:
            guard let digit = Int(key), (1...9).contains(digit) else { return false }
            selectTab(digit == 9 ? tabs.count - 1 : min(digit - 1, tabs.count - 1))
        }
        return true
    }

    override func interceptSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) -> Bool {
        if modifiers == .option && (key == .left || key == .right),
           desktop?.keyFocus?.acceptsTextInput != true {
            if key == .left { currentTab?.webView.goBack() } else { currentTab?.webView.goForward() }
            return true
        }
        if key == .tab && modifiers.contains(.control) && tabs.count > 1 {
            let step = modifiers.contains(.shift) ? -1 : 1
            selectTab((selectedIndex + step + tabs.count) % tabs.count)
            return true
        }
        return false
    }

    override func windowMenuItems() -> [MenuItem] {
        [MenuItem(title: "새 탭", symbol: "plus.square.on.square", shortcut: "⌘T") { [weak self] in self?.newTab() }]
    }

    override func willClose() {
        NotificationCenter.default.removeObserver(self)
        tabs.forEach { $0.close() }
        tabs.removeAll()
    }

    // MARK: Fullscreen

    func handleScriptMessage(_ body: [String: Any], from tab: BrowserTab) {
        guard let type = body["type"] as? String else { return }
        if type == "mediaPlayback" { PlaybackAudio.shared.activate(); return }
        guard tab === currentTab else { return }
        if type == "fullscreen" {
            setFullscreen(body["on"] as? Bool ?? false)
        }
    }

    private func setFullscreen(_ on: Bool) {
        guard on != isFullscreen, let window = deskWindow, let desktop else { return }
        isFullscreen = on
        desktop.setWindowFullscreen(window, on)
        setNeedsLayout()
        if on {
            desktop.showToast("Esc를 누르면 전체 화면이 종료됩니다", symbol: "arrow.down.right.and.arrow.up.left")
        }
    }

    override func exitFullscreen() {
        currentTab?.page("window.__pdExitFullscreen && window.__pdExitFullscreen()")
        setFullscreen(false)
    }

    // MARK: Virtual pointer → page

    private func buttonName(_ button: PointerButton) -> String {
        switch button {
        case .left: return "left"
        case .right: return "right"
        case .middle: return "middle"
        }
    }

    fileprivate func webPointerDown(_ event: PointerEvent) -> Bool {
        guard let tab = currentTab, errorView.isHidden else { return false }
        focusAddressOnActivate = false
        desktop?.setKeyFocus(tab.keyTarget)
        let point = event.location(in: tab.webView)
        let size = tab.webView.bounds.size
        tab.bridge("__pd.down(\(point.x),\(point.y),\(size.width),\(size.height),'\(buttonName(event.button))',\(event.clickCount),\(event.modifiers.jsObject))") { [weak tab] value in
            tab?.keyTarget.update(from: value)
        }
        return true
    }

    fileprivate func webPointerDragged(_ event: PointerEvent) {
        guard let tab = currentTab else { return }
        let now = CACurrentMediaTime()
        guard now - lastDragTime > 1.0 / 90 else { return }
        lastDragTime = now
        let point = event.location(in: tab.webView)
        let size = tab.webView.bounds.size
        tab.bridge("__pd.move(\(point.x),\(point.y),\(size.width),\(size.height),\(event.modifiers.jsObject))")
    }

    fileprivate func webPointerUp(_ event: PointerEvent) {
        guard let tab = currentTab else { return }
        let point = event.location(in: tab.webView)
        let size = tab.webView.bounds.size
        let location = event.location
        let button = event.button
        tab.bridge("__pd.up(\(point.x),\(point.y),\(size.width),\(size.height),\(event.modifiers.jsObject))") { [weak self, weak tab] value in
            guard let self, let tab, let info = value as? [String: Any] else { return }
            tab.keyTarget.update(from: info)
            if info["newTab"] as? Bool == true, let link = info["link"] as? String, let url = URL(string: link) {
                self.openTab(url: url, select: false)
                self.desktop?.showToast("새 탭에서 열었습니다", symbol: "plus.square.on.square")
                return
            }
            if let select = info["select"] as? [String: Any] {
                self.showSelectMenu(select, viewport: info, tab: tab)
                return
            }
            if button == .right, info["contextmenu"] as? Bool == true {
                self.showWebContextMenu(info, tab: tab, at: location)
            }
        }
    }

    fileprivate func webHover(_ event: PointerEvent) {
        guard let tab = currentTab else { return }
        hoverToken += 1
        let token = hoverToken
        let now = CACurrentMediaTime()
        guard now - lastHoverTime > 0.05 else {
            // Make sure the final resting position is delivered too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.hoverToken == token else { return }
                self.webHover(event)
            }
            return
        }
        lastHoverTime = now
        let point = event.location(in: tab.webView)
        let size = tab.webView.bounds.size
        tab.bridge("__pd.hover(\(point.x),\(point.y),\(size.width),\(size.height))") { [weak self] value in
            guard let self, let info = value as? [String: Any], let cursor = info["cursor"] as? String else { return }
            self.webCursor = BrowserContent.cursorKind(css: cursor)
        }
    }

    fileprivate func webPointerExited() {
        hoverToken += 1
        currentTab?.bridge("__pd.leave()")
        webCursor = .arrow
    }

    static func cursorKind(css: String) -> CursorKind {
        switch css {
        case "pointer": return .hand
        case "text", "vertical-text": return .text
        case "ew-resize", "col-resize", "e-resize", "w-resize": return .resizeHorizontal
        case "ns-resize", "row-resize", "n-resize", "s-resize": return .resizeVertical
        case "nwse-resize", "nw-resize", "se-resize": return .resizeDiagonalDown
        case "nesw-resize", "ne-resize", "sw-resize": return .resizeDiagonalUp
        case "move", "grab", "grabbing", "all-scroll": return .move
        default: return .arrow
        }
    }

    fileprivate func webScroll(by delta: CGPoint, event: PointerEvent) -> Bool {
        guard let tab = currentTab else { return false }
        let web = tab.webView
        let point = event.location(in: web)
        let now = CACurrentMediaTime()
        if now - lastScrollTime > 0.3 || hypot(point.x - lastScrollPoint.x, point.y - lastScrollPoint.y) > 30 {
            scrollMode = .unknown
        }
        lastScrollTime = now
        lastScrollPoint = point
        let size = web.bounds.size
        switch scrollMode {
        case .native:
            _ = web.scrollView.deskScroll(by: delta)
        case .page:
            tab.bridge("__pd.scrollMore(\(delta.x),\(delta.y),\(size.width))") { [weak web] value in
                if (value as? [String: Any])?["handled"] as? Bool == false {
                    _ = web?.scrollView.deskScroll(by: delta)
                }
            }
        case .pending:
            pendingScroll.x += delta.x
            pendingScroll.y += delta.y
        case .unknown:
            scrollMode = .pending
            pendingScroll = .zero
            tab.bridge("__pd.scrollStart(\(point.x),\(point.y),\(size.width),\(size.height),\(delta.x),\(delta.y))") { [weak self, weak tab] value in
                guard let self, let tab else { return }
                let handled = (value as? [String: Any])?["handled"] as? Bool ?? false
                let queued = self.pendingScroll
                self.pendingScroll = .zero
                if handled {
                    self.scrollMode = .page
                    if queued != .zero {
                        tab.bridge("__pd.scrollMore(\(queued.x),\(queued.y),\(size.width))")
                    }
                } else {
                    self.scrollMode = .native
                    _ = tab.webView.scrollView.deskScroll(by: CGPoint(x: delta.x + queued.x, y: delta.y + queued.y))
                }
            }
        }
        return true
    }

    private func showSelectMenu(_ select: [String: Any], viewport: [String: Any], tab: BrowserTab) {
        guard let desktop, let options = select["options"] as? [[String: Any]], !options.isEmpty else { return }
        let selected = select["selected"] as? Int ?? -1
        let scale = max(CGFloat(viewport["k"] as? Double ?? 1), 0.01)
        let offsetX = CGFloat(viewport["ox"] as? Double ?? 0)
        let offsetY = CGFloat(viewport["oy"] as? Double ?? 0)
        let x = CGFloat(select["x"] as? Double ?? 0)
        let y = CGFloat(select["y"] as? Double ?? 0)
        let local = CGPoint(x: (x - offsetX) / scale, y: (y - offsetY) / scale)
        let point = tab.webView.convert(local, to: desktop.rootView)
        let items = options.enumerated().map { index, option in
            MenuItem(title: option["label"] as? String ?? "", isEnabled: !(option["disabled"] as? Bool ?? false), isChecked: index == selected) { [weak tab] in
                tab?.bridge("__pd.choose(\(index))")
            }
        }
        desktop.showContextMenu(items, at: point)?.scrollToItem(selected)
    }

    private func showWebContextMenu(_ info: [String: Any], tab: BrowserTab, at point: CGPoint) {
        guard let desktop else { return }
        var items: [MenuItem] = []
        if let link = info["link"] as? String, let url = URL(string: link) {
            items += [
                MenuItem(title: "새 탭에서 링크 열기", symbol: "plus.square.on.square") { [weak self] in self?.openTab(url: url, select: false) },
                MenuItem(title: "새 창에서 링크 열기", symbol: "macwindow.badge.plus") { desktop.open(.browser, url: url) },
                MenuItem(title: "링크 주소 복사", symbol: "link") { UIPasteboard.general.string = link },
                .separator,
            ]
        }
        if let image = info["image"] as? String, !image.isEmpty, let url = URL(string: image) {
            items += [
                MenuItem(title: "새 탭에서 이미지 열기", symbol: "photo") { [weak self] in self?.openTab(url: url) },
                MenuItem(title: "이미지 주소 복사", symbol: "doc.on.doc") { UIPasteboard.general.string = image },
                .separator,
            ]
        }
        if let selection = info["selection"] as? String, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let preview = selection.count > 16 ? String(selection.prefix(16)) + "…" : selection
            items += [
                MenuItem(title: "복사", symbol: "doc.on.doc", shortcut: "⌘C") { UIPasteboard.general.string = selection },
                MenuItem(title: "'\(preview)' 검색", symbol: "magnifyingglass") { [weak self] in
                    if let url = Settings.shared.searchEngine.url(for: selection) { self?.openTab(url: url) }
                },
                .separator,
            ]
        }
        if info["editable"] as? Bool == true {
            items += [
                MenuItem(title: "붙여넣기", symbol: "doc.on.clipboard", shortcut: "⌘V", isEnabled: UIPasteboard.general.hasStrings) { [weak tab] in
                    if let text = UIPasteboard.general.string { tab?.keyTarget.insertText(text) }
                },
                .separator,
            ]
        }
        items += [
            MenuItem(title: "뒤로", symbol: "chevron.left", shortcut: "⌘[", isEnabled: tab.webView.canGoBack) { [weak tab] in tab?.webView.goBack() },
            MenuItem(title: "앞으로", symbol: "chevron.right", shortcut: "⌘]", isEnabled: tab.webView.canGoForward) { [weak tab] in tab?.webView.goForward() },
            MenuItem(title: "새로고침", symbol: "arrow.clockwise", shortcut: "⌘R") { [weak tab] in tab?.retry() },
            .separator,
            MenuItem(title: "바탕화면에 바로가기 추가", symbol: "plus.rectangle.on.rectangle") { [weak self] in self?.addCurrentPageToDesktop() },
        ]
        desktop.showContextMenu(items, at: point)
    }

    // MARK: WKNavigationDelegate

    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    private func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.webView === webView }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = BrowserEnvironment.contentMode
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        if let scheme = navigationAction.request.url?.scheme?.lowercased(), !BrowserContent.webSchemes.contains(scheme) {
            decisionHandler(.cancel, preferences)
            desktop?.showToast("앱 전용 링크(\(scheme):)는 데스크톱에서 열 수 없습니다", symbol: "exclamationmark.triangle")
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = DownloadManager.shared
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab(for: webView)?.errorMessage = nil
        if tab(for: webView) === currentTab { if isFullscreen { exitFullscreen() }; updateChrome() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.errorMessage = nil
        tab.isEditableFocused = false
        if tab === currentTab {
            scrollMode = .unknown
            updateChrome()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if tab(for: webView) === currentTab { if isFullscreen { exitFullscreen() }; updateChrome() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error, in: webView)
    }

    private func handleNavigationError(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return }
        guard let tab = tab(for: webView) else { return }
        tab.errorMessage = nsError.localizedDescription
        if tab === currentTab { updateChrome() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let isPopup = windowFeatures.width != nil || windowFeatures.height != nil
        if isPopup, let desktop {
            let window = desktop.open(.browser, configuration: configuration)
            return (window.content as? BrowserContent)?.currentTab?.webView
        }
        let tab = addTab(configuration: configuration, select: true, at: selectedIndex + 1)
        focusAddressOnActivate = false
        if deskWindow?.isActive == true { desktop?.setKeyFocus(tab.keyTarget) }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let index = tabs.firstIndex(where: { $0.webView === webView }) { closeTab(index) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        guard let desktop else {
            completionHandler()
            return
        }
        desktop.alert(title: frame.request.url?.host ?? "웹페이지", message: message) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let desktop else {
            completionHandler(false)
            return
        }
        desktop.confirm(title: frame.request.url?.host ?? "웹페이지", message: message) { completionHandler($0) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let desktop else {
            completionHandler(nil)
            return
        }
        desktop.prompt(title: frame.request.url?.host ?? "웹페이지", message: prompt, text: defaultText ?? "") { completionHandler($0) }
    }
}

// MARK: - Tab strip

final class BrowserTabStrip: UIView, PointerTarget {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    private var buttons: [BrowserTabButton] = []
    private let newTabButton = DeskButton(symbol: "plus")

    override init(frame: CGRect) {
        super.init(frame: frame)
        newTabButton.symbolSize = 13
        newTabButton.onTap = { [weak self] in self?.onNewTab?() }
        addSubview(newTabButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(titles: [String], loading: [Bool], selected: Int) {
        while buttons.count < titles.count {
            let button = BrowserTabButton()
            insertSubview(button, belowSubview: newTabButton)
            buttons.append(button)
        }
        while buttons.count > titles.count {
            buttons.removeLast().removeFromSuperview()
        }
        for (index, button) in buttons.enumerated() {
            button.title = titles[index]
            button.isLoadingTab = index < loading.count ? loading[index] : false
            button.isToggled = index == selected
            button.onTap = { [weak self] in self?.onSelect?(index) }
            button.onCloseTab = { [weak self] in self?.onClose?(index) }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let top = Theme.s(5)
        let height = bounds.height - top
        let newWidth = Theme.s(30)
        let available = bounds.width - Theme.s(12) - newWidth - Theme.s(6)
        let count = CGFloat(max(1, buttons.count))
        let width = min(Theme.s(220), max(Theme.s(70), available / count))
        var x = Theme.s(6)
        for button in buttons {
            button.frame = CGRect(x: x, y: top, width: width, height: height)
            x += width + Theme.s(2)
        }
        newTabButton.frame = CGRect(x: min(x + Theme.s(2), bounds.width - newWidth - Theme.s(4)), y: top + (height - newWidth) / 2, width: newWidth, height: newWidth)
    }

    func pointerDown(_ event: PointerEvent) -> Bool {
        if event.button == .left && event.clickCount == 2 { onNewTab?() }
        return true
    }
}

final class BrowserTabButton: DeskButton {
    var onCloseTab: (() -> Void)?
    var isLoadingTab = false { didSet { updateLoading() } }
    private let closeButton = DeskButton(symbol: "xmark")
    private let spinner = UIActivityIndicatorView(style: .medium)

    init() {
        super.init(symbol: "globe")
        alignment = .leading
        fontSize = 12
        symbolSize = 11
        cornerRadius = 7
        horizontalPadding = 10
        toggledBackground = Theme.panel
        hoverBackground = UIColor(white: 1, alpha: 0.06)
        closeButton.symbolSize = 9
        closeButton.symbolWeight = .bold
        closeButton.cornerRadius = 4
        closeButton.onTap = { [weak self] in self?.onCloseTab?() }
        addSubview(closeButton)
        spinner.color = Theme.secondaryText
        spinner.hidesWhenStopped = true
        spinner.isUserInteractionEnabled = false
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateLoading() {
        if isLoadingTab {
            spinner.startAnimating()
            iconView.alpha = 0
        } else {
            spinner.stopAnimating()
            iconView.alpha = 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let closeSize = Theme.s(18)
        closeButton.frame = CGRect(x: bounds.width - closeSize - Theme.s(6), y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        if titleLabel.frame.maxX > closeButton.frame.minX - Theme.s(4) {
            titleLabel.frame.size.width = max(0, closeButton.frame.minX - Theme.s(4) - titleLabel.frame.minX)
        }
        spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        spinner.center = iconView.center
    }

    override func pointerDown(_ event: PointerEvent) -> Bool {
        if event.button == .middle {
            onCloseTab?()
            return true
        }
        return super.pointerDown(event)
    }
}
