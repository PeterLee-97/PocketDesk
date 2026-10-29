import UIKit
import WebKit

final class DesktopRootView: UIView, PointerTarget, CursorProvider {
    weak var desktop: DesktopViewController?

    func pointerDown(_ event: PointerEvent) -> Bool {
        desktop?.desktopBackgroundPressed(event)
        return true
    }

    func cursor(at point: CGPoint) -> CursorKind? { .arrow }
}

final class WallpaperView: UIView {
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradient)
        glow.type = .radial
        glow.colors = [UIColor(white: 1, alpha: 0.14).cgColor, UIColor(white: 1, alpha: 0).cgColor]
        glow.startPoint = CGPoint(x: 0.28, y: 0.18)
        glow.endPoint = CGPoint(x: 1.0, y: 1.1)
        layer.addSublayer(glow)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(index: Int) {
        if index < 0, let image = UIImage(contentsOfFile: FileStore.wallpaperFile.path) {
            imageView.image = image
            imageView.isHidden = false
            glow.isHidden = true
        } else {
            imageView.image = nil
            imageView.isHidden = true
            glow.isHidden = false
            let preset = Wallpaper.presets[min(max(index, 0), Wallpaper.presets.count - 1)]
            gradient.colors = preset.colors.map { $0.cgColor }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        glow.frame = bounds
        CATransaction.commit()
        imageView.frame = bounds
    }
}

/// Lets a plain UIControl respond to the virtual pointer.
private final class ControlPointerAdapter: PointerTarget {
    let control: UIControl

    init(_ control: UIControl) { self.control = control }

    func pointerDown(_ event: PointerEvent) -> Bool {
        control.isHighlighted = true
        return true
    }

    func pointerDragged(_ event: PointerEvent) {
        control.isHighlighted = control.bounds.contains(event.location(in: control))
    }

    func pointerUp(_ event: PointerEvent) {
        control.isHighlighted = false
        if control.bounds.contains(event.location(in: control)) {
            control.sendActions(for: .touchUpInside)
        }
    }
}

/// Root of the external display: wallpaper, icons, windows, taskbar, overlays and the cursor.
/// It owns the pointer/keyboard routing and the window manager.
final class DesktopViewController: UIViewController {
    enum SnapTarget { case left, right, maximize }

    let rootView = DesktopRootView()
    private let wallpaperView = WallpaperView()
    private let iconsView = DesktopIconsView()
    private let windowLayer = PassthroughView()
    private let snapPreview = UIView()
    private let taskbar = TaskbarView()
    private let overlayLayer = PassthroughView()
    private let cursorView = CursorView()

    private(set) var windows: [DeskWindow] = []
    /// Most recently focused first.
    private(set) var focusOrder: [DeskWindow] = []
    private(set) weak var activeWindow: DeskWindow?
    private(set) weak var keyFocus: KeyInputTarget?

    private var startMenu: StartMenuView?
    private weak var focusBeforeStartMenu: KeyInputTarget?
    private var contextMenu: ContextMenuView?
    private var dialogs: [DialogView] = []
    private var toast: ToastView?
    private var toastToken = 0
    private var switcher: SwitcherHUD?
    private var switcherList: [DeskWindow] = []
    private var switcherIndex = 0
    private var switcherTime: CFTimeInterval = 0
    private var switcherToken = 0

    private(set) var cursorLocation = CGPoint(x: 200, y: 200)
    private var pressedButton: PointerButton?
    private var captureTarget: PointerTarget?
    private weak var hoverTarget: HoverTarget?
    private var lastClickTime: CFTimeInterval = 0
    private var lastClickLocation: CGPoint = .zero
    private var lastClickButton: PointerButton = .left
    private var clickCount = 1
    private var pendingSnap: SnapTarget?
    private var lastLayoutSize: CGSize = .zero
    private var hasAppeared = false

    override func loadView() {
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rootView.desktop = self
        rootView.backgroundColor = .black
        rootView.clipsToBounds = true
        for layerView in [wallpaperView, iconsView, windowLayer, taskbar, overlayLayer, cursorView] as [UIView] {
            rootView.addSubview(layerView)
        }
        snapPreview.isUserInteractionEnabled = false
        snapPreview.backgroundColor = UIColor(white: 1, alpha: 0.12)
        snapPreview.layer.borderColor = UIColor(white: 1, alpha: 0.45).cgColor
        snapPreview.layer.borderWidth = 2
        snapPreview.isHidden = true
        windowLayer.addSubview(snapPreview)
        taskbar.desktop = self
        iconsView.desktop = self
        iconsView.reload()
        wallpaperView.apply(index: Settings.shared.wallpaperIndex)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)), name: Settings.didChange, object: nil)
        updateTaskbar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAppeared else { return }
        hasAppeared = true
        if !Settings.shared.hasShownHelp {
            Settings.shared.hasShownHelp = true
            open(.help)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = rootView.bounds.size
        guard size.width > 0, size != lastLayoutSize else { return }
        if lastLayoutSize == .zero {
            cursorLocation = CGPoint(x: size.width / 2, y: size.height / 2)
        }
        lastLayoutSize = size
        applyThemeScale()
        layoutDesktop()
        windows.forEach(fitWindowToWorkArea)
        cursorLocation = clamp(cursorLocation)
        cursorView.place(at: cursorLocation)
    }

    // MARK: Layout

    private var taskbarHeight: CGFloat { Theme.s(48) }

    var workArea: CGRect {
        let bounds = rootView.bounds
        return CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - taskbarHeight))
    }

    private func applyThemeScale() {
        let size = rootView.bounds.size
        guard size.height > 0 else { return }
        let automatic = (min(max(size.height / 1000, 0.8), 2.5) * 4).rounded() / 4
        let setting = Settings.shared.uiScale
        let scale = CGFloat(setting > 0 ? setting : automatic)
        guard scale != Theme.scale else { return }
        Theme.scale = scale
        cursorView.refreshForTheme()
        NotificationCenter.default.post(name: Theme.didChange, object: nil)
        rootView.setNeedsLayoutRecursively()
    }

    private func layoutDesktop() {
        let bounds = rootView.bounds
        wallpaperView.frame = bounds
        taskbar.frame = CGRect(x: 0, y: bounds.height - taskbarHeight, width: bounds.width, height: taskbarHeight)
        iconsView.frame = workArea
        windowLayer.frame = bounds
        overlayLayer.frame = bounds
        for dialog in dialogs { dialog.frame = bounds }
        startMenu?.frame = startMenuFrame()
    }

    private func fitWindowToWorkArea(_ window: DeskWindow) {
        if window.isFullscreen {
            window.frame = rootView.bounds
            return
        }
        if window.isMaximized {
            window.frame = workArea
            return
        }
        if window.snap != .none {
            window.frame = snapFrame(window.snap)
            return
        }
        let area = workArea
        var frame = window.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = min(max(frame.minX, area.minX - frame.width + Theme.s(90)), area.maxX - Theme.s(90))
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - window.titleBarHeight)
        window.frame = frame
    }

    // MARK: Pointer input

    private func clamp(_ point: CGPoint) -> CGPoint {
        let bounds = rootView.bounds
        return CGPoint(x: min(max(point.x, 0), max(0, bounds.width - 1)), y: min(max(point.y, 0), max(0, bounds.height - 1)))
    }

    private func makeEvent(button: PointerButton) -> PointerEvent {
        PointerEvent(location: cursorLocation, button: button, clickCount: clickCount,
                     modifiers: HardwareInput.shared.currentModifiers, root: rootView)
    }

    func movePointer(by delta: CGPoint) {
        guard rootView.bounds.width > 0 else { return }
        cursorLocation = clamp(CGPoint(x: cursorLocation.x + delta.x, y: cursorLocation.y + delta.y))
        cursorView.place(at: cursorLocation)
        if let target = captureTarget, let button = pressedButton {
            let event = makeEvent(button: button)
            target.pointerDragged(event)
            if let provider = target as? CursorProvider, let view = target as? UIView,
               let kind = provider.cursor(at: event.location(in: view)) {
                cursorView.setKind(kind)
            }
        } else {
            updateHover()
        }
    }

    private func updateHover() {
        let hit = rootView.hitTest(cursorLocation, with: nil)
        let target = hit?.firstAncestor(ofType: HoverTarget.self)
        if target !== hoverTarget {
            hoverTarget?.pointerExited()
            hoverTarget = target
            target?.pointerEntered()
        }
        target?.pointerMoved(makeEvent(button: .left))
        cursorView.setKind(cursorKind(for: hit))
    }

    private func cursorKind(for hit: UIView?) -> CursorKind {
        var view = hit
        while let current = view {
            if let provider = current as? CursorProvider,
               let kind = provider.cursor(at: rootView.convert(cursorLocation, to: current)) {
                return kind
            }
            view = current.superview
        }
        return .arrow
    }

    func pointerButton(_ button: PointerButton, pressed: Bool) {
        if pressed {
            guard pressedButton == nil else { return }
            pressedButton = button
            let now = CACurrentMediaTime()
            let distance = hypot(cursorLocation.x - lastClickLocation.x, cursorLocation.y - lastClickLocation.y)
            if button == lastClickButton, now - lastClickTime < 0.45, distance < Theme.s(8) {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickLocation = cursorLocation
            lastClickButton = button

            let event = makeEvent(button: button)
            let hit = rootView.hitTest(cursorLocation, with: nil)
            dismissTransientUI(for: hit)
            if let window = hit?.enclosingDeskWindow {
                if window !== activeWindow || window.isMinimized { focus(window) }
            } else if let hit, hit === rootView || hit.isDescendant(of: iconsView) {
                deactivateWindows()
            }

            captureTarget = nil
            var view = hit
            while let current = view {
                if let target = current as? PointerTarget {
                    if target.pointerDown(event) {
                        captureTarget = target
                        break
                    }
                } else if let control = current as? UIControl, control.isEnabled {
                    let adapter = ControlPointerAdapter(control)
                    _ = adapter.pointerDown(event)
                    captureTarget = adapter
                    break
                }
                view = current.superview
            }
        } else {
            guard pressedButton == button else { return }
            pressedButton = nil
            let event = makeEvent(button: button)
            let target = captureTarget
            captureTarget = nil
            target?.pointerUp(event)
            updateHover()
        }
    }

    func scroll(by delta: CGPoint) {
        let hit = rootView.hitTest(cursorLocation, with: nil)
        let event = makeEvent(button: .left)
        var view = hit
        while let current = view {
            if let target = current as? ScrollTarget, target.scroll(by: delta, event: event) { return }
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled, scrollView.deskScroll(by: delta) { return }
            view = current.superview
        }
    }

    func cancelPointerInteraction() {
        if let button = pressedButton { pointerButton(button, pressed: false) }
    }

    func centerPointer() {
        let bounds = rootView.bounds
        cursorLocation = CGPoint(x: bounds.midX, y: bounds.midY)
        cursorView.place(at: cursorLocation)
        updateHover()
    }

    private func dismissTransientUI(for hit: UIView?) {
        if let menu = contextMenu, !(hit?.isDescendant(of: menu) ?? false) {
            dismissContextMenu()
        }
        if let start = startMenu, !(hit?.isDescendant(of: start) ?? false), !(hit?.isDescendant(of: taskbar.startButton) ?? false) {
            closeStartMenu()
        }
        if !(hit?.isDescendant(of: iconsView) ?? false) {
            iconsView.select(nil)
        }
    }

    func desktopBackgroundPressed(_ event: PointerEvent) {
        iconsView.select(nil)
        if event.button == .right {
            showContextMenu(desktopMenu(), at: event.location)
        }
    }

    private func desktopMenu() -> [MenuItem] {
        [
            MenuItem(title: "새 브라우저 창", symbol: "globe") { [weak self] in self?.open(.browser) },
            MenuItem(title: "새 메모", symbol: "square.and.pencil") { [weak self] in self?.open(.notes) },
            MenuItem(title: "바로가기 추가…", symbol: "plus.square.on.square") { [weak self] in self?.promptAddShortcut() },
            .separator,
            MenuItem(title: "배경화면 · 디스플레이 설정", symbol: "photo.on.rectangle") { [weak self] in self?.open(.settings) },
            MenuItem(title: "모든 창 최소화", symbol: "menubar.dock.rectangle") { [weak self] in self?.minimizeAll() },
            .separator,
            MenuItem(title: "도움말", symbol: "questionmark.circle") { [weak self] in self?.open(.help) },
        ]
    }

    // MARK: Keyboard input

    func setKeyFocus(_ target: KeyInputTarget?) {
        guard target !== keyFocus else { return }
        let previous = keyFocus
        keyFocus = target
        previous?.keyFocusChanged(false)
        target?.keyFocusChanged(true)
        DeskSession.shared.keyFocusDidChange()
    }

    /// Call when the focused target's `acceptsTextInput` / `inputDescription` changed.
    func keyFocusStateChanged() {
        DeskSession.shared.keyFocusDidChange()
    }

    func keyboardInsertText(_ text: String) {
        if contextMenu != nil { dismissContextMenu() }
        keyFocus?.insertText(text)
    }

    func keyboardDeleteBackward() {
        keyFocus?.deleteBackward()
    }

    func keyboardSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        if let menu = contextMenu {
            switch key {
            case .up: menu.moveHighlight(by: -1)
            case .down: menu.moveHighlight(by: 1)
            case .enter: menu.activateHighlighted()
            case .escape: dismissContextMenu()
            default: break
            }
            return
        }
        if key == .escape && modifiers.hasShortcutKey {
            toggleStartMenu()
            return
        }
        if key == .escape, startMenu != nil {
            closeStartMenu()
            return
        }
        if key == .tab, dialogs.isEmpty, modifiers.contains(.option) || modifiers.contains(.command) {
            cycleWindows(backward: modifiers.contains(.shift))
            return
        }
        if key == .escape, dialogs.isEmpty, let window = activeWindow, window.isFullscreen {
            window.content.exitFullscreen()
            return
        }
        if dialogs.isEmpty, startMenu == nil, let content = activeWindow?.content,
           content.interceptSpecialKey(key, modifiers: modifiers) {
            return
        }
        keyFocus?.handleSpecialKey(key, modifiers: modifiers)
    }

    func keyboardShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        if dialogs.isEmpty && startMenu == nil {
            if let content = activeWindow?.content, content.handleShortcut(key, modifiers: modifiers) { return true }
            if handleDesktopShortcut(key, modifiers: modifiers) { return true }
        }
        return keyFocus?.handleShortcut(key, modifiers: modifiers) ?? false
    }

    private func handleDesktopShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "w":
            if let window = activeWindow { close(window) }
            return true
        case "t":
            open(.browser)
            return true
        case "n":
            if let kind = activeWindow?.kind, !kind.isSingleInstance, kind != .imageViewer, kind != .pdfViewer, kind != .mediaPlayer, kind != .textEditor {
                open(kind)
            } else {
                open(.browser)
            }
            return true
        case "m":
            if let window = activeWindow { minimize(window) }
            return true
        case ",":
            open(.settings)
            return true
        default:
            return false
        }
    }

    // MARK: Windows

    @discardableResult
    func open(_ kind: AppKind, url: URL? = nil, fileURL: URL? = nil, configuration: WKWebViewConfiguration? = nil) -> DeskWindow {
        if kind.isSingleInstance, let existing = windows.first(where: { $0.kind == kind }) {
            focus(existing)
            return existing
        }
        let content = kind.makeContent(url: url, fileURL: fileURL, configuration: configuration)
        let window = DeskWindow(kind: kind, content: content)
        window.desktop = self
        window.frame = initialFrame(for: kind)
        windowLayer.addSubview(window)
        windows.append(window)
        focus(window)
        window.animateIn()
        return window
    }

    private func initialFrame(for kind: AppKind) -> CGRect {
        let area = workArea
        let size = kind.defaultSize(in: area.size)
        let step = Theme.s(28)
        let offset = CGFloat(windows.count % 6) - 2
        var origin = CGPoint(
            x: area.midX - size.width / 2 + offset * step,
            y: area.minY + max(Theme.s(12), (area.height - size.height) / 2 - Theme.s(30)) + offset * step * 0.7
        )
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }

    func focus(_ window: DeskWindow) {
        if let fullscreen = windows.first(where: { $0.isFullscreen && $0 !== window }) {
            fullscreen.content.exitFullscreen()
            setWindowFullscreen(fullscreen, false)
        }
        if window.isMinimized { restoreMinimized(window) }
        windowLayer.bringSubviewToFront(window)
        windows.removeAll { $0 === window }
        windows.append(window)
        focusOrder.removeAll { $0 === window }
        focusOrder.insert(window, at: 0)
        if activeWindow !== window {
            activeWindow?.isActive = false
            activeWindow = window
            window.isActive = true
            window.content.didActivate()
            setKeyFocus(window.content.preferredKeyTarget)
        }
        updateTaskbar()
    }

    private func deactivateWindows() {
        guard let window = activeWindow else { return }
        window.isActive = false
        activeWindow = nil
        setKeyFocus(nil)
        updateTaskbar()
    }

    func close(_ window: DeskWindow) {
        guard windows.contains(where: { $0 === window }) else { return }
        if window.isFullscreen { setWindowFullscreen(window, false) }
        window.content.willClose()
        windows.removeAll { $0 === window }
        focusOrder.removeAll { $0 === window }
        if let captured = captureTarget as? UIView, captured.isDescendant(of: window) {
            captureTarget = nil
            pressedButton = nil
        }
        if let hovered = hoverTarget as? UIView, hovered.isDescendant(of: window) {
            hoverTarget = nil
        }
        let wasActive = activeWindow === window
        if wasActive {
            activeWindow = nil
            setKeyFocus(nil)
        }
        window.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.12, animations: {
            window.alpha = 0
            window.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }, completion: { _ in
            window.removeFromSuperview()
        })
        if wasActive, let next = focusOrder.first(where: { !$0.isMinimized }) {
            focus(next)
        }
        updateTaskbar()
    }

    func closeAllWindows() {
        for window in windows { close(window) }
    }

    func minimize(_ window: DeskWindow) {
        guard !window.isMinimized else { return }
        if window.isFullscreen {
            window.content.exitFullscreen()
            setWindowFullscreen(window, false)
        }
        window.isMinimized = true
        let target = taskbar.buttonCenter(for: window.kind).map { taskbar.convert($0, to: windowLayer) }
            ?? CGPoint(x: workArea.midX, y: rootView.bounds.maxY)
        let dx = target.x - window.center.x
        let dy = target.y - window.center.y
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn], animations: {
            window.transform = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: 0.12, y: 0.12)
            window.alpha = 0
        }, completion: { _ in
            guard window.isMinimized else { return }
            window.isHidden = true
            window.transform = .identity
            window.alpha = 1
        })
        if activeWindow === window {
            window.isActive = false
            activeWindow = nil
            setKeyFocus(nil)
            if let next = focusOrder.first(where: { !$0.isMinimized }) { focus(next) }
        }
        updateTaskbar()
    }

    func minimizeAll() {
        for window in windows where !window.isMinimized { minimize(window) }
    }

    private func restoreMinimized(_ window: DeskWindow) {
        window.isMinimized = false
        window.transform = .identity
        window.isHidden = false
        window.alpha = 0
        UIView.animate(withDuration: 0.15) { window.alpha = 1 }
    }

    func toggleMaximize(_ window: DeskWindow) {
        if window.isMaximized || window.snap != .none {
            restoreSize(window)
        } else {
            maximize(window)
        }
    }

    func maximize(_ window: DeskWindow) {
        if !window.isMaximized && window.snap == .none { window.restoreFrame = window.frame }
        window.snap = .none
        window.isMaximized = true
        animateFrame(window, to: workArea)
        focus(window)
    }

    func restoreSize(_ window: DeskWindow) {
        let target = window.restoreFrame ?? initialFrame(for: window.kind)
        window.isMaximized = false
        window.snap = .none
        animateFrame(window, to: target)
    }

    func snapWindow(_ window: DeskWindow, to side: SnapSide) {
        guard side != .none else {
            restoreSize(window)
            return
        }
        if !window.isMaximized && window.snap == .none { window.restoreFrame = window.frame }
        window.isMaximized = false
        window.snap = side
        animateFrame(window, to: snapFrame(side))
        focus(window)
    }

    private func snapFrame(_ side: SnapSide) -> CGRect {
        let area = workArea
        let half = (area.width / 2).rounded()
        switch side {
        case .left: return CGRect(x: area.minX, y: area.minY, width: half, height: area.height)
        case .right: return CGRect(x: area.minX + half, y: area.minY, width: area.width - half, height: area.height)
        case .none: return area
        }
    }

    private func animateFrame(_ window: DeskWindow, to frame: CGRect) {
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            window.frame = frame
            window.layoutIfNeeded()
        }
    }

    func updateSnapPreview(for window: DeskWindow, cursor: CGPoint) {
        let bounds = rootView.bounds
        let edge = max(2, Theme.s(3))
        var target: SnapTarget?
        if cursor.y <= edge {
            target = .maximize
        } else if cursor.x <= edge {
            target = .left
        } else if cursor.x >= bounds.width - 1 - edge {
            target = .right
        }
        guard target != pendingSnap else { return }
        pendingSnap = target
        if let target {
            let frame: CGRect
            switch target {
            case .maximize: frame = workArea
            case .left: frame = snapFrame(.left)
            case .right: frame = snapFrame(.right)
            }
            windowLayer.insertSubview(snapPreview, belowSubview: window)
            if snapPreview.isHidden {
                snapPreview.frame = CGRect(x: cursor.x - 10, y: cursor.y - 10, width: 20, height: 20)
                snapPreview.alpha = 0
                snapPreview.isHidden = false
            }
            snapPreview.layer.cornerRadius = Theme.s(10)
            UIView.animate(withDuration: 0.15) {
                self.snapPreview.frame = frame.insetBy(dx: Theme.s(6), dy: Theme.s(6))
                self.snapPreview.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.12, animations: {
                self.snapPreview.alpha = 0
            }, completion: { _ in
                if self.pendingSnap == nil { self.snapPreview.isHidden = true }
            })
        }
    }

    func finishWindowDrag(_ window: DeskWindow) {
        if let target = pendingSnap {
            switch target {
            case .maximize: maximize(window)
            case .left: snapWindow(window, to: .left)
            case .right: snapWindow(window, to: .right)
            }
        }
        pendingSnap = nil
        snapPreview.isHidden = true
    }

    /// Edge-to-edge window without chrome or taskbar (web video fullscreen, media player).
    func setWindowFullscreen(_ window: DeskWindow, _ on: Bool) {
        if on {
            guard !window.isFullscreen else { return }
            window.fullscreenRestore = (window.frame, window.isMaximized, window.snap)
            window.isChromeHidden = true
            focus(window)
            window.frame = rootView.bounds
            taskbar.isHidden = true
        } else {
            guard let restore = window.fullscreenRestore else { return }
            window.fullscreenRestore = nil
            window.isChromeHidden = false
            window.isMaximized = restore.maximized
            window.snap = restore.snap
            window.frame = restore.frame
            taskbar.isHidden = windows.contains { $0.isFullscreen }
        }
    }

    func windowTitlesChanged() {
        updateTaskbar()
    }

    private func updateTaskbar() {
        taskbar.update(windows: windows, active: activeWindow)
    }

    func taskbarAppClicked(_ kind: AppKind) {
        let appWindows = focusOrder.filter { $0.kind == kind }
        guard !appWindows.isEmpty else {
            open(kind)
            return
        }
        if appWindows.count == 1 {
            let window = appWindows[0]
            if window === activeWindow && !window.isMinimized {
                minimize(window)
            } else {
                focus(window)
            }
            return
        }
        let anchor = taskbar.buttonCenter(for: kind).map { taskbar.convert($0, to: rootView) } ?? cursorLocation
        var items = appWindows.map { window in
            MenuItem(title: window.displayTitle, symbol: window.isMinimized ? "minus.square" : "macwindow", isChecked: window === activeWindow) { [weak self, weak window] in
                if let window { self?.focus(window) }
            }
        }
        items.append(.separator)
        items.append(MenuItem(title: "새 창", symbol: "plus") { [weak self] in self?.open(kind) })
        showContextMenu(items, at: anchor, above: true)
    }

    func showTaskbarMenu(for kind: AppKind, at point: CGPoint) {
        var items = [MenuItem(title: "새 창 열기", symbol: "plus") { [weak self] in self?.open(kind) }]
        let appWindows = windows.filter { $0.kind == kind }
        if !appWindows.isEmpty {
            items.append(MenuItem(title: appWindows.count > 1 ? "모든 창 닫기" : "창 닫기", symbol: "xmark", isDestructive: true) { [weak self] in
                appWindows.forEach { self?.close($0) }
            })
        }
        showContextMenu(items, at: point, above: true)
    }

    func cycleWindows(backward: Bool) {
        let now = CACurrentMediaTime()
        if now - switcherTime > 1.0 || switcherList.isEmpty {
            switcherList = focusOrder
            switcherIndex = 0
        }
        switcherTime = now
        switcherList.removeAll { window in !windows.contains { $0 === window } }
        guard !switcherList.isEmpty else { return }
        if switcherList.count > 1 {
            switcherIndex = (switcherIndex + (backward ? -1 : 1) + switcherList.count) % switcherList.count
        } else {
            switcherIndex = 0
        }
        focus(switcherList[switcherIndex])
        switcher?.removeFromSuperview()
        let hud = SwitcherHUD(windows: switcherList, selected: switcherIndex)
        let size = hud.preferredSize(maxWidth: rootView.bounds.width - Theme.s(80))
        hud.frame = CGRect(x: (rootView.bounds.width - size.width) / 2, y: (rootView.bounds.height - size.height) / 2, width: size.width, height: size.height)
        overlayLayer.addSubview(hud)
        switcher = hud
        switcherToken += 1
        let token = switcherToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.switcherToken == token else { return }
            self.switcher?.removeFromSuperview()
            self.switcher = nil
        }
    }

    // MARK: Start menu

    func toggleStartMenu() {
        if startMenu == nil { openStartMenu() } else { closeStartMenu() }
    }

    func openStartMenu() {
        guard startMenu == nil else { return }
        dismissContextMenu()
        let menu = StartMenuView(desktop: self)
        menu.frame = startMenuFrame()
        overlayLayer.addSubview(menu)
        startMenu = menu
        focusBeforeStartMenu = keyFocus
        setKeyFocus(menu.searchField)
        taskbar.startButton.isToggled = true
        menu.alpha = 0
        menu.transform = CGAffineTransform(translationX: 0, y: Theme.s(16))
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
            menu.alpha = 1
            menu.transform = .identity
        }
    }

    func closeStartMenu() {
        guard let menu = startMenu else { return }
        startMenu = nil
        taskbar.startButton.isToggled = false
        menu.isUserInteractionEnabled = false
        if keyFocus === menu.searchField {
            setKeyFocus(focusBeforeStartMenu ?? activeWindow?.content.preferredKeyTarget)
        }
        UIView.animate(withDuration: 0.12, animations: {
            menu.alpha = 0
            menu.transform = CGAffineTransform(translationX: 0, y: Theme.s(10))
        }, completion: { _ in
            menu.removeFromSuperview()
        })
    }

    private func startMenuFrame() -> CGRect {
        let size = StartMenuView.preferredSize(in: rootView.bounds.size)
        return CGRect(x: Theme.s(8), y: workArea.maxY - size.height - Theme.s(8), width: size.width, height: size.height)
    }

    // MARK: Menus, dialogs, toasts

    @discardableResult
    func showContextMenu(_ items: [MenuItem], at point: CGPoint, above: Bool = false) -> ContextMenuView? {
        dismissContextMenu()
        guard !items.isEmpty else { return nil }
        let menu = ContextMenuView(items: items)
        menu.onPick = { [weak self] item in
            self?.dismissContextMenu()
            item.action?()
        }
        let bounds = rootView.bounds
        var size = menu.preferredSize()
        size.height = min(size.height, bounds.height - 8)
        var origin = above
            ? CGPoint(x: point.x - size.width / 2, y: point.y - size.height - Theme.s(14))
            : CGPoint(x: point.x + 2, y: point.y + 2)
        if origin.x + size.width > bounds.width - 4 {
            origin.x = above ? bounds.width - size.width - 4 : point.x - size.width - 2
        }
        if origin.y + size.height > bounds.height - 4 {
            origin.y = point.y - size.height - 2
        }
        origin.x = max(4, origin.x)
        origin.y = max(4, origin.y)
        menu.frame = CGRect(origin: origin, size: size)
        overlayLayer.addSubview(menu)
        contextMenu = menu
        menu.alpha = 0
        UIView.animate(withDuration: 0.1) { menu.alpha = 1 }
        return menu
    }

    func dismissContextMenu() {
        guard let menu = contextMenu else { return }
        contextMenu = nil
        if hoverTarget === menu { hoverTarget = nil }
        menu.removeFromSuperview()
    }

    @discardableResult
    func showDialog(title: String, message: String? = nil, fieldText: String? = nil, placeholder: String? = nil,
                    buttons: [DialogView.Button]) -> DialogView {
        dismissContextMenu()
        if startMenu != nil { closeStartMenu() }
        let dialog = DialogView(title: title, message: message, fieldText: fieldText, placeholder: placeholder, buttons: buttons)
        dialog.previousFocus = keyFocus
        dialog.onFinish = { [weak self, weak dialog] in
            if let dialog { self?.closeDialog(dialog) }
        }
        dialog.frame = rootView.bounds
        overlayLayer.addSubview(dialog)
        dialogs.append(dialog)
        focusDialog(dialog)
        dialog.alpha = 0
        UIView.animate(withDuration: 0.12) { dialog.alpha = 1 }
        return dialog
    }

    private func focusDialog(_ dialog: DialogView) {
        if let field = dialog.field {
            setKeyFocus(field)
        } else {
            setKeyFocus(dialog)
        }
    }

    private func closeDialog(_ dialog: DialogView) {
        dialogs.removeAll { $0 === dialog }
        let previous = dialog.previousFocus
        dialog.removeFromSuperview()
        if let top = dialogs.last {
            focusDialog(top)
        } else {
            setKeyFocus(previous ?? activeWindow?.content.preferredKeyTarget)
        }
    }

    func alert(title: String, message: String?, completion: (() -> Void)? = nil) {
        showDialog(title: title, message: message, buttons: [
            DialogView.Button(title: "확인", style: .primary) { _ in completion?() },
        ])
    }

    func confirm(title: String, message: String?, confirmTitle: String = "확인", destructive: Bool = false,
                 completion: @escaping (Bool) -> Void) {
        showDialog(title: title, message: message, buttons: [
            DialogView.Button(title: "취소", style: .cancel) { _ in completion(false) },
            DialogView.Button(title: confirmTitle, style: destructive ? .destructive : .primary) { _ in completion(true) },
        ])
    }

    func prompt(title: String, message: String?, text: String, placeholder: String = "", confirmTitle: String = "확인",
                completion: @escaping (String?) -> Void) {
        showDialog(title: title, message: message, fieldText: text, placeholder: placeholder, buttons: [
            DialogView.Button(title: "취소", style: .cancel) { _ in completion(nil) },
            DialogView.Button(title: confirmTitle, style: .primary) { value in completion(value) },
        ])
    }

    func showToast(_ message: String, symbol: String? = "info.circle") {
        toast?.removeFromSuperview()
        let view = ToastView(message: message, symbol: symbol)
        let size = view.preferredSize(maxWidth: min(Theme.s(440), rootView.bounds.width - 40))
        view.frame = CGRect(x: rootView.bounds.width - size.width - Theme.s(16), y: workArea.maxY - size.height - Theme.s(16),
                            width: size.width, height: size.height)
        overlayLayer.addSubview(view)
        toast = view
        toastToken += 1
        let token = toastToken
        view.alpha = 0
        view.transform = CGAffineTransform(translationX: 0, y: Theme.s(10))
        UIView.animate(withDuration: 0.18) {
            view.alpha = 1
            view.transform = .identity
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak view] in
            guard let self, let view, self.toastToken == token else { return }
            UIView.animate(withDuration: 0.25, animations: { view.alpha = 0 }, completion: { _ in view.removeFromSuperview() })
        }
    }

    // MARK: Opening things

    func openWeb(_ url: URL, newWindow: Bool = false) {
        if !newWindow, let window = focusOrder.first(where: { $0.kind == .browser }), let browser = window.content as? BrowserContent {
            browser.openTab(url: url)
            focus(window)
        } else {
            open(.browser, url: url)
        }
    }

    func openUserInput(_ text: String) {
        if let url = Settings.shared.url(fromUserInput: text) { openWeb(url) }
    }

    func openFile(_ url: URL) {
        switch FileStore.kind(of: url) {
        case .folder: open(.files, fileURL: url)
        case .image: open(.imageViewer, fileURL: url)
        case .pdf: open(.pdfViewer, fileURL: url)
        case .video, .audio: open(.mediaPlayer, fileURL: url)
        case .text: open(.textEditor, fileURL: url)
        case .web, .document: open(.browser, fileURL: url)
        case .archive, .other:
            showToast("이 파일 형식은 열 수 없습니다: \(url.lastPathComponent)", symbol: "exclamationmark.triangle")
        }
    }

    func promptAddShortcut(title: String = "", url: String = "") {
        prompt(title: "바탕화면 바로가기 추가", message: "바로가기로 만들 웹 주소를 입력하세요.", text: url, placeholder: "https://example.com") { [weak self] text in
            guard let self, let text, let parsed = Settings.shared.url(fromUserInput: text) else { return }
            let host = (parsed.host ?? text).replacingOccurrences(of: "www.", with: "")
            self.addShortcut(WebShortcut(title: title.isEmpty ? host : title, url: parsed.absoluteString))
        }
    }

    func addShortcut(_ shortcut: WebShortcut) {
        var shortcuts = Settings.shared.shortcuts
        shortcuts.removeAll { $0.url == shortcut.url }
        shortcuts.append(shortcut)
        Settings.shared.shortcuts = shortcuts
        showToast("바탕화면에 '\(shortcut.title)' 바로가기를 추가했습니다", symbol: "plus.square.on.square")
    }

    func wallpaperImageDidChange() {
        wallpaperView.apply(index: Settings.shared.wallpaperIndex)
    }

    @objc private func settingsChanged(_ notification: Notification) {
        guard let key = notification.userInfo?["key"] as? String else { return }
        switch key {
        case "wallpaperIndex":
            wallpaperView.apply(index: Settings.shared.wallpaperIndex)
        case "uiScale":
            applyThemeScale()
            layoutDesktop()
            windows.forEach(fitWindowToWorkArea)
            cursorView.place(at: cursorLocation)
        case "shortcuts":
            iconsView.reload()
        default:
            break
        }
    }
}
