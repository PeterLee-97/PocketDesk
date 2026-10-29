import UIKit

enum SnapSide {
    case none, left, right
}

/// A movable, resizable window hosting one app's content.
final class DeskWindow: UIView, PointerTarget, CursorProvider {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    private enum Drag {
        case none, move, resize(Edges)
    }

    let kind: AppKind
    let content: AppContentView
    weak var desktop: DesktopViewController?

    var isActive = false { didSet { updateAppearance() } }
    var isMaximized = false { didSet { updateMaximizeIcon(); setNeedsLayout() } }
    var isMinimized = false
    var snap: SnapSide = .none { didSet { updateMaximizeIcon() } }
    /// Frame to return to after maximize/snap.
    var restoreFrame: CGRect?
    var isChromeHidden = false { didSet { setNeedsLayout(); updateAppearance() } }
    var fullscreenRestore: (frame: CGRect, maximized: Bool, snap: SnapSide)?
    var isFullscreen: Bool { fullscreenRestore != nil }

    private let chrome = UIView()
    private let titleBar = UIView()
    private let iconTile: IconTileView
    private let titleLabel = UILabel()
    private let minimizeButton = DeskButton(symbol: "minus")
    private let maximizeButton = DeskButton(symbol: "square")
    private let closeButton = DeskButton(symbol: "xmark")
    private let contentContainer = UIView()

    private var drag: Drag = .none
    private var dragStartPoint: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var dragMoved = false
    private var pendingDoubleClick = false

    static var minimumSize: CGSize { CGSize(width: Theme.s(300), height: Theme.s(180)) }
    var titleBarHeight: CGFloat { isChromeHidden ? 0 : Theme.s(38) }
    private var outerResizeMargin: CGFloat { Theme.s(7) }
    private var innerResizeMargin: CGFloat { Theme.s(3) }

    var displayTitle: String { content.title.isEmpty ? kind.title : content.title }

    init(kind: AppKind, content: AppContentView) {
        self.kind = kind
        self.content = content
        self.iconTile = IconTileView(style: kind.iconStyle)
        super.init(frame: .zero)
        content.deskWindow = self
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 10)
        layer.shadowRadius = 26
        chrome.clipsToBounds = true
        chrome.backgroundColor = Theme.windowBackground
        chrome.layer.borderWidth = 1
        addSubview(chrome)
        contentContainer.clipsToBounds = true
        chrome.addSubview(contentContainer)
        contentContainer.addSubview(content)
        chrome.addSubview(titleBar)
        titleBar.addSubview(iconTile)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        titleBar.addSubview(titleLabel)
        for button in [minimizeButton, maximizeButton, closeButton] {
            button.cornerRadius = 0
            button.symbolSize = 12
            titleBar.addSubview(button)
        }
        closeButton.hoverBackground = Theme.danger
        closeButton.pressedBackground = Theme.danger.withAlphaComponent(0.7)
        minimizeButton.onTap = { [weak self] in
            guard let self else { return }
            self.desktop?.minimize(self)
        }
        maximizeButton.onTap = { [weak self] in
            guard let self else { return }
            self.desktop?.toggleMaximize(self)
        }
        closeButton.onTap = { [weak self] in
            guard let self else { return }
            self.desktop?.close(self)
        }
        titleLabel.text = displayTitle
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius: CGFloat = (isMaximized || isChromeHidden) ? 0 : Theme.s(10)
        chrome.frame = bounds
        chrome.layer.cornerRadius = radius
        chrome.layer.borderWidth = isChromeHidden ? 0 : 1
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        let barHeight = titleBarHeight
        titleBar.isHidden = isChromeHidden
        titleBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let buttonWidth = Theme.s(46)
        closeButton.frame = CGRect(x: bounds.width - buttonWidth, y: 0, width: buttonWidth, height: barHeight)
        maximizeButton.frame = closeButton.frame.offsetBy(dx: -buttonWidth, dy: 0)
        minimizeButton.frame = maximizeButton.frame.offsetBy(dx: -buttonWidth, dy: 0)
        let iconSize = Theme.s(18)
        iconTile.frame = CGRect(x: Theme.s(12), y: (barHeight - iconSize) / 2, width: iconSize, height: iconSize)
        titleLabel.font = Theme.font(12.5, .medium)
        let titleX = iconTile.frame.maxX + Theme.s(9)
        titleLabel.frame = CGRect(x: titleX, y: 0, width: max(0, minimizeButton.frame.minX - titleX - Theme.s(8)), height: barHeight)
        contentContainer.frame = CGRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))
        content.frame = contentContainer.bounds
    }

    func titleDidChange() {
        titleLabel.text = displayTitle
        desktop?.windowTitlesChanged()
    }

    private func updateAppearance() {
        titleBar.backgroundColor = isActive ? Theme.titleBarActive : Theme.titleBarInactive
        titleLabel.textColor = isActive ? Theme.text : Theme.secondaryText
        iconTile.alpha = isActive ? 1 : 0.65
        layer.shadowOpacity = isChromeHidden ? 0 : (isActive ? 0.5 : 0.25)
        chrome.layer.borderColor = (isActive ? UIColor(white: 1, alpha: 0.17) : Theme.border).cgColor
    }

    private func updateMaximizeIcon() {
        maximizeButton.symbolName = (isMaximized || snap != .none) ? "square.on.square" : "square"
    }

    func animateIn() {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    // MARK: Hit testing (resize handles extend slightly outside the window)

    private var canResize: Bool { !isMaximized && !isChromeHidden }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard canResize else { return bounds.contains(point) }
        return bounds.insetBy(dx: -outerResizeMargin, dy: -outerResizeMargin).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, self.point(inside: point, with: event) else { return nil }
        if !resizeEdges(at: point).isEmpty { return self }
        return super.hitTest(point, with: event)
    }

    private func resizeEdges(at point: CGPoint) -> Edges {
        guard canResize else { return [] }
        var edges: Edges = []
        if point.x < innerResizeMargin { edges.insert(.left) } else if point.x > bounds.width - innerResizeMargin { edges.insert(.right) }
        if point.y < innerResizeMargin { edges.insert(.top) } else if point.y > bounds.height - innerResizeMargin { edges.insert(.bottom) }
        return edges
    }

    // MARK: PointerTarget

    func pointerDown(_ event: PointerEvent) -> Bool {
        let point = event.location(in: self)
        if event.button == .right {
            guard point.y < titleBarHeight else { return false }
            desktop?.showContextMenu(windowMenu(), at: event.location)
            return true
        }
        guard event.button == .left else { return false }
        let edges = resizeEdges(at: point)
        if !edges.isEmpty {
            drag = .resize(edges)
            dragStartPoint = event.location
            dragStartFrame = frame
            snap = .none
            return true
        }
        if point.y < titleBarHeight {
            // A double-click maximizes on release, unless it turns into a drag
            // (double-tap-and-drag is how the phone trackpad moves windows).
            drag = .move
            dragStartPoint = event.location
            dragStartFrame = frame
            dragMoved = false
            pendingDoubleClick = event.clickCount == 2
            return true
        }
        return false
    }

    func pointerDragged(_ event: PointerEvent) {
        guard let desktop else { return }
        let dx = event.location.x - dragStartPoint.x
        let dy = event.location.y - dragStartPoint.y
        let area = desktop.workArea
        switch drag {
        case .none:
            return
        case .move:
            if !dragMoved {
                guard hypot(dx, dy) > 3 else { return }
                dragMoved = true
                if isMaximized || snap != .none {
                    // Pull the window out of its maximized/snapped state, keeping it under the cursor.
                    let restored = restoreFrame ?? CGRect(origin: .zero, size: kind.defaultSize(in: area.size))
                    let ratio = (dragStartPoint.x - frame.minX) / max(frame.width, 1)
                    let newFrame = CGRect(
                        x: dragStartPoint.x - restored.width * ratio,
                        y: max(area.minY, dragStartPoint.y - titleBarHeight / 2),
                        width: restored.width, height: restored.height
                    )
                    isMaximized = false
                    snap = .none
                    frame = newFrame
                    dragStartFrame = newFrame
                }
            }
            var newFrame = dragStartFrame.offsetBy(dx: dx, dy: dy)
            newFrame.origin.y = min(max(newFrame.origin.y, area.minY), area.maxY - titleBarHeight)
            newFrame.origin.x = min(max(newFrame.origin.x, area.minX - newFrame.width + Theme.s(90)), area.maxX - Theme.s(90))
            frame = newFrame
            desktop.updateSnapPreview(for: self, cursor: event.location)
        case .resize(let edges):
            var newFrame = dragStartFrame
            let minimum = DeskWindow.minimumSize
            if edges.contains(.left) {
                let x = min(newFrame.maxX - minimum.width, newFrame.minX + dx)
                newFrame.size.width = newFrame.maxX - x
                newFrame.origin.x = x
            }
            if edges.contains(.right) {
                newFrame.size.width = max(minimum.width, dragStartFrame.width + dx)
            }
            if edges.contains(.top) {
                let y = min(newFrame.maxY - minimum.height, max(area.minY, newFrame.minY + dy))
                newFrame.size.height = newFrame.maxY - y
                newFrame.origin.y = y
            }
            if edges.contains(.bottom) {
                newFrame.size.height = max(minimum.height, dragStartFrame.height + dy)
            }
            frame = newFrame
        }
    }

    func pointerUp(_ event: PointerEvent) {
        if case .move = drag {
            if dragMoved {
                desktop?.finishWindowDrag(self)
            } else if pendingDoubleClick {
                desktop?.toggleMaximize(self)
            }
        }
        pendingDoubleClick = false
        drag = .none
    }

    func cursor(at point: CGPoint) -> CursorKind? {
        let edges: Edges
        if case .resize(let active) = drag {
            edges = active
        } else {
            edges = resizeEdges(at: point)
        }
        if edges == [.left] || edges == [.right] { return .resizeHorizontal }
        if edges == [.top] || edges == [.bottom] { return .resizeVertical }
        if edges == [.left, .top] || edges == [.right, .bottom] { return .resizeDiagonalDown }
        if edges == [.right, .top] || edges == [.left, .bottom] { return .resizeDiagonalUp }
        return point.y < titleBarHeight ? .arrow : nil
    }

    // MARK: Menu

    func windowMenu() -> [MenuItem] {
        var items = content.windowMenuItems()
        if !items.isEmpty { items.append(.separator) }
        items += [
            MenuItem(title: "최소화", symbol: "minus", shortcut: "⌘M") { [weak self] in
                guard let self else { return }
                self.desktop?.minimize(self)
            },
            MenuItem(title: (isMaximized || snap != .none) ? "이전 크기로" : "최대화", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in
                guard let self else { return }
                self.desktop?.toggleMaximize(self)
            },
            MenuItem(title: "왼쪽 절반에 배치", symbol: "rectangle.lefthalf.filled") { [weak self] in
                guard let self else { return }
                self.desktop?.snapWindow(self, to: .left)
            },
            MenuItem(title: "오른쪽 절반에 배치", symbol: "rectangle.righthalf.filled") { [weak self] in
                guard let self else { return }
                self.desktop?.snapWindow(self, to: .right)
            },
            .separator,
            MenuItem(title: "닫기", symbol: "xmark", shortcut: "⌘W", isDestructive: true) { [weak self] in
                guard let self else { return }
                self.desktop?.close(self)
            },
        ]
        return items
    }
}
