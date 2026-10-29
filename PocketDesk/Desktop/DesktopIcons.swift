import UIKit

/// Shortcut icons laid out in columns on the wallpaper.
final class DesktopIconsView: PassthroughView {
    weak var desktop: DesktopViewController?
    private var icons: [DesktopIconView] = []

    func reload() {
        icons.forEach { $0.removeFromSuperview() }
        var created: [DesktopIconView] = []
        for kind in AppKind.desktopIcons {
            let icon = DesktopIconView(style: kind.iconStyle, title: kind.title)
            icon.onOpen = { [weak self] in self?.desktop?.open(kind) }
            icon.menuProvider = { [weak self] in
                [MenuItem(title: "열기", symbol: "arrow.up.forward.app") { self?.desktop?.open(kind) }]
            }
            created.append(icon)
        }
        for shortcut in Settings.shared.shortcuts {
            let icon = DesktopIconView(style: ShortcutIcons.style(for: shortcut), title: shortcut.title)
            let url = URL(string: shortcut.url)
            icon.onOpen = { [weak self] in
                if let url { self?.desktop?.openWeb(url) }
            }
            icon.menuProvider = { [weak self] in
                [
                    MenuItem(title: "열기", symbol: "arrow.up.forward.app") {
                        if let url { self?.desktop?.openWeb(url) }
                    },
                    MenuItem(title: "새 창에서 열기", symbol: "macwindow.badge.plus") {
                        if let url { self?.desktop?.openWeb(url, newWindow: true) }
                    },
                    .separator,
                    MenuItem(title: "바로가기 삭제", symbol: "trash", isDestructive: true) {
                        var shortcuts = Settings.shared.shortcuts
                        shortcuts.removeAll { $0 == shortcut }
                        Settings.shared.shortcuts = shortcuts
                    },
                ]
            }
            created.append(icon)
        }
        for icon in created {
            icon.container = self
            addSubview(icon)
        }
        icons = created
        setNeedsLayout()
    }

    func select(_ icon: DesktopIconView?) {
        for candidate in icons { candidate.isSelected = candidate === icon }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cellWidth = Theme.s(92)
        let cellHeight = Theme.s(100)
        let margin = Theme.s(14)
        let rows = max(1, Int((bounds.height - margin) / cellHeight))
        for (index, icon) in icons.enumerated() {
            let column = index / rows
            let row = index % rows
            icon.frame = CGRect(x: margin + CGFloat(column) * cellWidth, y: margin + CGFloat(row) * cellHeight, width: cellWidth - Theme.s(6), height: cellHeight - Theme.s(6))
        }
    }
}

final class DesktopIconView: UIView, PointerTarget, HoverTarget {
    var isSelected = false { didSet { updateBackground() } }
    var onOpen: (() -> Void)?
    var menuProvider: (() -> [MenuItem])?
    weak var container: DesktopIconsView?

    private let tile: IconTileView
    private let label = UILabel()
    private var isPointerOver = false

    init(style: IconTileView.Style, title: String) {
        self.tile = IconTileView(style: style)
        super.init(frame: .zero)
        addSubview(tile)
        label.text = title
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateBackground() {
        if isSelected {
            backgroundColor = UIColor(hex: 0x4A8FFF, alpha: 0.3)
        } else {
            backgroundColor = isPointerOver ? UIColor(white: 1, alpha: 0.1) : .clear
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(8)
        let size = Theme.s(50)
        tile.frame = CGRect(x: (bounds.width - size) / 2, y: Theme.s(8), width: size, height: size)
        label.font = Theme.font(12, .medium)
        let labelY = tile.frame.maxY + Theme.s(6)
        let labelWidth = bounds.width - Theme.s(6)
        let fitted = label.sizeThatFits(CGSize(width: labelWidth, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(x: Theme.s(3), y: labelY, width: labelWidth, height: max(0, min(ceil(fitted.height), bounds.height - labelY)))
    }

    func pointerDown(_ event: PointerEvent) -> Bool {
        container?.select(self)
        switch event.button {
        case .left:
            break
        case .right:
            if let items = menuProvider?() {
                DeskSession.shared.desktop?.showContextMenu(items, at: event.location)
            }
        case .middle:
            break
        }
        return true
    }

    func pointerUp(_ event: PointerEvent) {
        guard event.button == .left, event.clickCount == 1, bounds.contains(event.location(in: self)) else { return }
        container?.select(nil)
        onOpen?()
    }

    func pointerEntered() {
        isPointerOver = true
        updateBackground()
    }

    func pointerExited() {
        isPointerOver = false
        updateBackground()
    }
}
