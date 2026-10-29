import UIKit

// MARK: - Menu model

struct MenuItem {
    var title: String
    var symbol: String?
    var shortcut: String?
    var isEnabled: Bool
    var isDestructive: Bool
    var isChecked: Bool
    var isSeparator = false
    var action: (() -> Void)?

    init(title: String, symbol: String? = nil, shortcut: String? = nil, isEnabled: Bool = true,
         isDestructive: Bool = false, isChecked: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.isChecked = isChecked
        self.action = action
    }

    static var separator: MenuItem {
        var item = MenuItem(title: "")
        item.isSeparator = true
        item.isEnabled = false
        return item
    }
}

// MARK: - Context menu

final class ContextMenuView: UIView, PointerTarget, HoverTarget {
    private let items: [MenuItem]
    private let scrollView = UIScrollView()
    private var rows: [MenuRowView] = []
    private var highlighted: Int? { didSet { updateHighlight() } }
    var onPick: ((MenuItem) -> Void)?

    init(items: [MenuItem]) {
        self.items = items
        super.init(frame: .zero)
        backgroundColor = Theme.panel
        layer.borderWidth = 1
        layer.borderColor = Theme.border.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 8)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.indicatorStyle = .white
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        for item in items {
            let row = MenuRowView(item: item)
            rows.append(row)
            scrollView.addSubview(row)
        }
    }

    func scrollToItem(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        layoutIfNeeded()
        scrollView.scrollRectToVisible(rows[index].frame.insetBy(dx: 0, dy: -Theme.s(40)), animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func preferredSize() -> CGSize {
        var width = Theme.s(190)
        var height = Theme.s(10)
        for row in rows {
            width = max(width, row.preferredWidth())
            height += row.preferredHeight
        }
        return CGSize(width: min(width, Theme.s(440)), height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(9)
        scrollView.frame = bounds
        scrollView.layer.cornerRadius = layer.cornerRadius
        var y = Theme.s(5)
        for row in rows {
            let height = row.preferredHeight
            row.frame = CGRect(x: Theme.s(5), y: y, width: bounds.width - Theme.s(10), height: height)
            y += height
        }
        scrollView.contentSize = CGSize(width: bounds.width, height: y + Theme.s(5))
    }

    private func index(at point: CGPoint) -> Int? {
        let contentPoint = convert(point, to: scrollView)
        for (index, row) in rows.enumerated() where row.frame.contains(contentPoint) {
            let item = items[index]
            return (item.isSeparator || !item.isEnabled) ? nil : index
        }
        return nil
    }

    private func updateHighlight() {
        for (index, row) in rows.enumerated() { row.isHighlighted = index == highlighted }
    }

    func moveHighlight(by delta: Int) {
        let selectable = items.indices.filter { !items[$0].isSeparator && items[$0].isEnabled }
        guard !selectable.isEmpty else { return }
        if let current = highlighted, let position = selectable.firstIndex(of: current) {
            highlighted = selectable[(position + delta + selectable.count) % selectable.count]
        } else {
            highlighted = delta > 0 ? selectable.first : selectable.last
        }
    }

    func activateHighlighted() {
        guard let index = highlighted else { return }
        onPick?(items[index])
    }

    func pointerDown(_ event: PointerEvent) -> Bool {
        highlighted = index(at: event.location(in: self))
        return true
    }

    func pointerUp(_ event: PointerEvent) {
        guard let index = index(at: event.location(in: self)) else { return }
        onPick?(items[index])
    }

    func pointerMoved(_ event: PointerEvent) {
        let index = index(at: event.location(in: self))
        if index != highlighted { highlighted = index }
    }

    func pointerExited() {
        highlighted = nil
    }
}

private final class MenuRowView: UIView {
    let item: MenuItem
    var isHighlighted = false { didSet { updateColors() } }
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let shortcutLabel = UILabel()
    private let separator = UIView()

    init(item: MenuItem) {
        self.item = item
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        iconView.contentMode = .center
        titleLabel.text = item.title
        shortcutLabel.text = item.shortcut
        shortcutLabel.textAlignment = .right
        separator.backgroundColor = Theme.separator
        for view in [iconView, titleLabel, shortcutLabel, separator] { addSubview(view) }
        separator.isHidden = !item.isSeparator
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var preferredHeight: CGFloat { item.isSeparator ? Theme.s(9) : Theme.s(30) }

    func preferredWidth() -> CGFloat {
        guard !item.isSeparator else { return 0 }
        titleLabel.font = Theme.font(13)
        shortcutLabel.font = Theme.font(12)
        let title = titleLabel.sizeThatFits(CGSize(width: 1000, height: 100)).width
        let shortcut = (item.shortcut ?? "").isEmpty ? 0 : shortcutLabel.sizeThatFits(CGSize(width: 1000, height: 100)).width + Theme.s(24)
        return ceil(Theme.s(40) + title + shortcut + Theme.s(26))
    }

    private func updateColors() {
        backgroundColor = isHighlighted ? Theme.accent : .clear
        let color: UIColor
        if !item.isEnabled {
            color = Theme.tertiaryText
        } else if isHighlighted {
            color = .white
        } else {
            color = item.isDestructive ? Theme.danger : Theme.text
        }
        titleLabel.textColor = color
        iconView.tintColor = color
        shortcutLabel.textColor = isHighlighted ? UIColor(white: 1, alpha: 0.8) : Theme.secondaryText
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(5)
        if item.isSeparator {
            separator.frame = CGRect(x: Theme.s(6), y: bounds.height / 2, width: bounds.width - Theme.s(12), height: 1)
            return
        }
        titleLabel.font = Theme.font(13)
        shortcutLabel.font = Theme.font(12)
        let symbol = item.isChecked ? "checkmark" : item.symbol
        iconView.image = symbol.flatMap { Theme.symbol($0, size: 12, weight: .medium) }
        iconView.frame = CGRect(x: Theme.s(6), y: 0, width: Theme.s(24), height: bounds.height)
        let shortcutWidth = (item.shortcut ?? "").isEmpty ? 0 : Theme.s(70)
        shortcutLabel.frame = CGRect(x: bounds.width - shortcutWidth - Theme.s(10), y: 0, width: shortcutWidth, height: bounds.height)
        titleLabel.frame = CGRect(x: Theme.s(36), y: 0, width: bounds.width - Theme.s(46) - shortcutWidth, height: bounds.height)
    }
}

// MARK: - Dialog

final class DialogView: UIView, PointerTarget, KeyInputTarget {
    struct Button {
        enum Style { case normal, primary, destructive, cancel }
        let title: String
        let style: Style
        let action: (String?) -> Void
    }

    let field: DeskTextField?
    weak var previousFocus: KeyInputTarget?
    var onFinish: (() -> Void)?

    private let panel = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let buttons: [Button]
    private var buttonViews: [DeskButton] = []

    init(title: String, message: String?, fieldText: String?, placeholder: String?, buttons: [Button]) {
        self.buttons = buttons
        if let fieldText {
            let field = DeskTextField(placeholder: placeholder ?? "")
            field.text = fieldText
            field.selectsAllOnFocus = true
            self.field = field
        } else {
            self.field = nil
        }
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0, alpha: 0.38)
        panel.backgroundColor = Theme.panel
        panel.layer.borderWidth = 1
        panel.layer.borderColor = Theme.border.cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.5
        panel.layer.shadowRadius = 30
        addSubview(panel)
        titleLabel.text = title
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 2
        panel.addSubview(titleLabel)
        messageLabel.text = message
        messageLabel.textColor = Theme.secondaryText
        messageLabel.numberOfLines = 0
        panel.addSubview(messageLabel)
        if let field {
            field.onSubmit = { [weak self] _ in self?.finishPrimary() }
            field.onEscape = { [weak self] in self?.finishCancel() }
            panel.addSubview(field)
        }
        for button in buttons {
            let view = DeskButton(title: button.title)
            view.fontSize = 13
            view.horizontalPadding = 16
            switch button.style {
            case .primary:
                view.normalBackground = Theme.accent
                view.hoverBackground = Theme.accent.withAlphaComponent(0.85)
                view.tint = .white
            case .destructive:
                view.normalBackground = Theme.danger
                view.hoverBackground = Theme.danger.withAlphaComponent(0.85)
                view.tint = .white
            case .normal, .cancel:
                view.normalBackground = UIColor(white: 1, alpha: 0.1)
            }
            view.onTap = { [weak self] in self?.finish(with: button) }
            buttonViews.append(view)
            panel.addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(Theme.s(440), bounds.width - Theme.s(40))
        let padding = Theme.s(22)
        let innerWidth = width - padding * 2
        titleLabel.font = Theme.font(16, .semibold)
        messageLabel.font = Theme.font(13)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: innerWidth, height: 1000)).height)
        let hasMessage = !(messageLabel.text ?? "").isEmpty
        let messageHeight = hasMessage ? min(ceil(messageLabel.sizeThatFits(CGSize(width: innerWidth, height: 2000)).height), bounds.height * 0.5) : 0
        var y = padding
        titleLabel.frame = CGRect(x: padding, y: y, width: innerWidth, height: titleHeight)
        y += titleHeight + Theme.s(8)
        messageLabel.frame = CGRect(x: padding, y: y, width: innerWidth, height: messageHeight)
        y += messageHeight + (hasMessage ? Theme.s(14) : Theme.s(4))
        if let field {
            field.frame = CGRect(x: padding, y: y, width: innerWidth, height: Theme.s(34))
            y += Theme.s(34) + Theme.s(18)
        }
        let buttonHeight = Theme.s(32)
        var x = width - padding
        for view in buttonViews.reversed() {
            let buttonWidth = max(Theme.s(76), view.preferredWidth())
            x -= buttonWidth
            view.frame = CGRect(x: x, y: y, width: buttonWidth, height: buttonHeight)
            x -= Theme.s(8)
        }
        y += buttonHeight + padding
        panel.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - y) / 2 - Theme.s(30), width: width, height: y)
        panel.layer.cornerRadius = Theme.s(12)
    }

    private func finish(with button: Button) {
        let text = field?.text
        onFinish?()
        button.action(text)
    }

    func finishPrimary() {
        if let button = buttons.first(where: { $0.style == .primary || $0.style == .destructive }) ?? buttons.last {
            finish(with: button)
        }
    }

    func finishCancel() {
        if let button = buttons.first(where: { $0.style == .cancel }) {
            finish(with: button)
        } else if buttons.count == 1, let only = buttons.first {
            finish(with: only)
        }
    }

    // Modal: swallow every click that doesn't hit one of the dialog's own controls.
    func pointerDown(_ event: PointerEvent) -> Bool { true }

    // MARK: KeyInputTarget (used when the dialog has no text field)

    var acceptsTextInput: Bool { false }
    func insertText(_ text: String) {}
    func deleteBackward() {}

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        switch key {
        case .enter: finishPrimary()
        case .escape: finishCancel()
        default: break
        }
    }
}

// MARK: - Toast

final class ToastView: UIView {
    private let iconView = UIImageView()
    private let label = UILabel()
    private let symbol: String?

    init(message: String, symbol: String?) {
        self.symbol = symbol
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = Theme.panel.withAlphaComponent(0.97)
        layer.borderWidth = 1
        layer.borderColor = Theme.border.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 14
        iconView.tintColor = Theme.accent
        iconView.contentMode = .center
        label.text = message
        label.textColor = Theme.text
        label.numberOfLines = 2
        addSubview(iconView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        label.font = Theme.font(13)
        let iconWidth = symbol == nil ? 0 : Theme.s(26)
        let text = label.sizeThatFits(CGSize(width: maxWidth - iconWidth - Theme.s(32), height: 200))
        return CGSize(width: ceil(text.width + iconWidth + Theme.s(32)), height: max(Theme.s(44), ceil(text.height) + Theme.s(22)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(10)
        label.font = Theme.font(13)
        iconView.image = symbol.flatMap { Theme.symbol($0, size: 15, weight: .semibold) }
        let iconWidth = symbol == nil ? 0 : Theme.s(26)
        iconView.frame = CGRect(x: Theme.s(14), y: 0, width: iconWidth - Theme.s(4), height: bounds.height)
        label.frame = CGRect(x: Theme.s(16) + iconWidth, y: 0, width: bounds.width - iconWidth - Theme.s(32), height: bounds.height)
    }
}

// MARK: - Window switcher (Alt/⌘ + Tab)

final class SwitcherHUD: UIView {
    private let entries: [(IconTileView, UILabel)]
    private let selected: Int

    init(windows: [DeskWindow], selected: Int) {
        self.selected = selected
        self.entries = windows.map { window in
            let label = UILabel()
            label.text = window.displayTitle
            label.textColor = Theme.text
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            return (IconTileView(style: window.kind.iconStyle), label)
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = Theme.panel.withAlphaComponent(0.96)
        layer.borderWidth = 1
        layer.borderColor = Theme.border.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 24
        for (tile, label) in entries {
            addSubview(tile)
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var cellWidth: CGFloat { Theme.s(128) }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let width = min(maxWidth, CGFloat(entries.count) * cellWidth + Theme.s(24))
        return CGSize(width: width, height: Theme.s(132))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(14)
        let count = CGFloat(max(entries.count, 1))
        let cell = min(cellWidth, (bounds.width - Theme.s(24)) / count)
        for (index, entry) in entries.enumerated() {
            let x = Theme.s(12) + CGFloat(index) * cell
            let tileSize = Theme.s(54)
            entry.0.frame = CGRect(x: x + (cell - tileSize) / 2, y: Theme.s(20), width: tileSize, height: tileSize)
            entry.0.layer.borderWidth = index == selected ? max(2, Theme.s(2.5)) : 0
            entry.0.layer.borderColor = UIColor.white.cgColor
            entry.1.font = Theme.font(12, index == selected ? .semibold : .regular)
            entry.1.textColor = index == selected ? Theme.text : Theme.secondaryText
            entry.1.frame = CGRect(x: x + Theme.s(4), y: Theme.s(86), width: cell - Theme.s(8), height: Theme.s(30))
        }
    }
}
