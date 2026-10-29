import UIKit

// MARK: - Button

/// Button for the desktop. Driven by the virtual pointer (UIKit touch handling never runs on
/// the external display).
class DeskButton: UIControl, PointerTarget, HoverTarget, CursorProvider {
    enum Alignment { case center, leading }

    var onTap: (() -> Void)?
    var symbolName: String? { didSet { setNeedsLayout() } }
    var title: String? { didSet { titleLabel.text = title; setNeedsLayout() } }
    var symbolSize: CGFloat = 14 { didSet { setNeedsLayout() } }
    var symbolWeight: UIImage.SymbolWeight = .regular
    var fontSize: CGFloat = 13 { didSet { setNeedsLayout() } }
    var fontWeight: UIFont.Weight = .regular
    var cornerRadius: CGFloat = 6
    var horizontalPadding: CGFloat = 10
    var alignment: Alignment = .center
    var tint: UIColor = Theme.text { didSet { updateAppearance() } }
    var normalBackground: UIColor = .clear { didSet { updateAppearance() } }
    var hoverBackground: UIColor = Theme.hover
    var pressedBackground: UIColor = Theme.pressed
    var toggledBackground: UIColor = Theme.pressed
    var isToggled = false { didSet { updateAppearance() } }
    var showsHandCursor = false

    let iconView = UIImageView()
    let titleLabel = UILabel()
    private(set) var isPointerOver = false
    private(set) var isPointerPressed = false

    init(symbol: String? = nil, title: String? = nil, action: (() -> Void)? = nil) {
        self.symbolName = symbol
        self.title = title
        self.onTap = action
        super.init(frame: .zero)
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        titleLabel.isUserInteractionEnabled = false
        titleLabel.text = title
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(iconView)
        addSubview(titleLabel)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    private var symbolImage: UIImage? {
        symbolName.flatMap { Theme.symbol($0, size: symbolSize, weight: symbolWeight) }
    }

    func preferredWidth() -> CGFloat {
        titleLabel.font = Theme.font(fontSize, fontWeight)
        let titleWidth = (title ?? "").isEmpty ? 0 : ceil(titleLabel.sizeThatFits(CGSize(width: 2000, height: 200)).width)
        let iconWidth = symbolImage?.size.width ?? 0
        let gap: CGFloat = (iconWidth > 0 && titleWidth > 0) ? Theme.s(6) : 0
        return ceil(iconWidth + titleWidth + gap + Theme.s(horizontalPadding) * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(cornerRadius)
        titleLabel.font = Theme.font(fontSize, fontWeight)
        iconView.image = symbolImage
        let iconSize = iconView.image?.size ?? .zero
        let hasTitle = !(title ?? "").isEmpty
        let titleSize = hasTitle ? titleLabel.sizeThatFits(CGSize(width: 2000, height: bounds.height)) : .zero
        let padding = Theme.s(horizontalPadding)
        let gap: CGFloat = (iconSize.width > 0 && hasTitle) ? Theme.s(6) : 0
        let total = iconSize.width + gap + titleSize.width
        var x: CGFloat
        switch alignment {
        case .center: x = max(min(padding, bounds.width / 2), (bounds.width - total) / 2)
        case .leading: x = padding
        }
        if iconSize.width > 0 {
            iconView.frame = CGRect(x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
            x += iconSize.width + gap
        } else {
            iconView.frame = .zero
        }
        if hasTitle {
            let width = max(0, min(titleSize.width, bounds.width - x - padding / 2))
            titleLabel.frame = CGRect(x: x, y: (bounds.height - titleSize.height) / 2, width: width, height: titleSize.height)
        } else {
            titleLabel.frame = .zero
        }
    }

    func updateAppearance() {
        let background: UIColor
        if !isEnabled {
            background = normalBackground
        } else if isPointerPressed {
            background = pressedBackground
        } else if isToggled {
            background = isPointerOver ? toggledBackground.withAlphaComponent(min(1, toggledBackground.cgColor.alpha + 0.06)) : toggledBackground
        } else if isPointerOver {
            background = hoverBackground
        } else {
            background = normalBackground
        }
        backgroundColor = background
        let color = isEnabled ? tint : tint.withAlphaComponent(0.32)
        iconView.tintColor = color
        titleLabel.textColor = color
    }

    func pointerDown(_ event: PointerEvent) -> Bool {
        guard isEnabled, event.button == .left else { return false }
        isPointerPressed = true
        updateAppearance()
        return true
    }

    func pointerDragged(_ event: PointerEvent) {
        let inside = bounds.contains(event.location(in: self))
        if inside != isPointerPressed {
            isPointerPressed = inside
            updateAppearance()
        }
    }

    func pointerUp(_ event: PointerEvent) {
        let inside = bounds.contains(event.location(in: self))
        isPointerPressed = false
        updateAppearance()
        if inside && isEnabled {
            onTap?()
            sendActions(for: .primaryActionTriggered)
        }
    }

    func pointerEntered() {
        isPointerOver = true
        updateAppearance()
    }

    func pointerExited() {
        isPointerOver = false
        isPointerPressed = false
        updateAppearance()
    }

    func cursor(at point: CGPoint) -> CursorKind? {
        showsHandCursor ? .hand : .arrow
    }
}

// MARK: - Single-line text field

/// A text field rendered by hand: it receives keys from the desktop's key focus instead of
/// becoming first responder (the external display can't take keyboard focus).
final class DeskTextField: UIView, KeyInputTarget, PointerTarget, CursorProvider {
    var text: String = "" {
        didSet {
            if caret > text.count { caret = text.count }
            refresh()
        }
    }
    var placeholder: String = "" { didSet { placeholderLabel.text = placeholder } }
    var fontSize: CGFloat = 13 { didSet { setNeedsLayout() } }
    var isSecure = false
    var selectsAllOnFocus = false
    var keyboardType: UIKeyboardType = .default
    var inputDescription: String = "입력란"
    var onSubmit: ((String) -> Void)?
    var onChange: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onSpecialKey: ((SpecialKey) -> Bool)?

    private let clipView = UIView()
    private let label = UILabel()
    private let placeholderLabel = UILabel()
    private let caretView = UIView()
    private let selectionView = UIView()
    private var caret = 0
    private var allSelected = false
    private(set) var hasKeyFocus = false
    private var blinkTimer: Timer?
    private var scrollX: CGFloat = 0

    init(placeholder: String = "") {
        super.init(frame: .zero)
        backgroundColor = Theme.field
        layer.borderWidth = 1
        layer.borderColor = Theme.border.cgColor
        clipView.clipsToBounds = true
        clipView.isUserInteractionEnabled = false
        addSubview(clipView)
        selectionView.backgroundColor = Theme.selection
        clipView.addSubview(selectionView)
        label.textColor = Theme.text
        clipView.addSubview(label)
        placeholderLabel.textColor = Theme.tertiaryText
        placeholderLabel.text = placeholder
        self.placeholder = placeholder
        clipView.addSubview(placeholderLabel)
        caretView.backgroundColor = Theme.accent
        clipView.addSubview(caretView)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var font: UIFont { Theme.font(fontSize) }
    private var displayText: String { isSecure ? String(repeating: "•", count: text.count) : text }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(6)
        let inset = Theme.s(8)
        clipView.frame = bounds.insetBy(dx: inset, dy: 0)
        label.font = font
        placeholderLabel.font = font
        refresh()
    }

    private func width(of string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    private func refresh() {
        let shown = displayText
        label.text = shown
        placeholderLabel.isHidden = !text.isEmpty
        let available = clipView.bounds.width
        let height = clipView.bounds.height
        let lineHeight = ceil(font.lineHeight)
        let fullWidth = width(of: shown)
        let caretX = width(of: String(shown.prefix(caret)))
        if fullWidth <= available {
            scrollX = 0
        } else {
            if caretX - scrollX > available - 2 { scrollX = caretX - available + 2 }
            if caretX - scrollX < 0 { scrollX = caretX }
            scrollX = min(scrollX, fullWidth - available + 2)
        }
        let y = (height - lineHeight) / 2
        label.frame = CGRect(x: -scrollX, y: y, width: max(fullWidth + 4, available), height: lineHeight)
        placeholderLabel.frame = CGRect(x: 0, y: y, width: available, height: lineHeight)
        caretView.frame = CGRect(x: caretX - scrollX, y: y, width: max(1, Theme.s(1.5)), height: lineHeight)
        caretView.isHidden = !hasKeyFocus || (allSelected && !text.isEmpty)
        selectionView.isHidden = !(hasKeyFocus && allSelected && !text.isEmpty)
        selectionView.frame = CGRect(x: -scrollX, y: y, width: fullWidth, height: lineHeight)
        layer.borderColor = (hasKeyFocus ? Theme.accent : Theme.border).cgColor
        layer.borderWidth = hasKeyFocus ? max(1, Theme.s(1.5)) : 1
    }

    func selectAll() {
        allSelected = !text.isEmpty
        caret = text.count
        refresh()
    }

    func setText(_ newText: String, notify: Bool) {
        caret = newText.count
        allSelected = false
        text = newText
        if notify { onChange?(text) }
    }

    // MARK: KeyInputTarget

    var acceptsTextInput: Bool { true }

    func insertText(_ string: String) {
        let clean = string.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        var characters = Array(text)
        if allSelected {
            characters = []
            caret = 0
            allSelected = false
        }
        let insert = Array(clean)
        characters.insert(contentsOf: insert, at: min(caret, characters.count))
        caret = min(caret, characters.count) + insert.count
        text = String(characters)
        onChange?(text)
        restartBlink()
    }

    func deleteBackward() {
        if allSelected {
            allSelected = false
            caret = 0
            text = ""
            onChange?(text)
            return
        }
        guard caret > 0 else { return }
        var characters = Array(text)
        characters.remove(at: caret - 1)
        caret -= 1
        text = String(characters)
        onChange?(text)
        restartBlink()
    }

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        if let handler = onSpecialKey, handler(key) { return }
        switch key {
        case .left:
            if allSelected { allSelected = false; caret = 0 } else { caret = modifiers.hasShortcutKey ? 0 : max(0, caret - 1) }
        case .right:
            if allSelected { allSelected = false; caret = text.count } else { caret = modifiers.hasShortcutKey ? text.count : min(text.count, caret + 1) }
        case .home, .up, .pageUp:
            allSelected = false
            caret = 0
        case .end, .down, .pageDown:
            allSelected = false
            caret = text.count
        case .enter:
            onSubmit?(text)
        case .escape:
            onEscape?()
        case .backspace:
            deleteBackward()
            return
        case .deleteForward:
            if allSelected {
                deleteBackward()
                return
            }
            if caret < text.count {
                var characters = Array(text)
                characters.remove(at: caret)
                text = String(characters)
                onChange?(text)
            }
        case .tab:
            break
        }
        refresh()
        restartBlink()
    }

    func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "a":
            selectAll()
            return true
        case "c":
            if !isSecure { UIPasteboard.general.string = text }
            return true
        case "x":
            if !isSecure { UIPasteboard.general.string = text }
            setText("", notify: true)
            return true
        case "v":
            if let pasted = UIPasteboard.general.string { insertText(pasted) }
            return true
        default:
            return false
        }
    }

    func keyFocusChanged(_ focused: Bool) {
        hasKeyFocus = focused
        if focused {
            caret = text.count
            allSelected = selectsAllOnFocus && !text.isEmpty
            restartBlink()
        } else {
            allSelected = false
            stopBlink()
        }
        refresh()
        onFocusChange?(focused)
    }

    // MARK: Caret blinking

    private func restartBlink() {
        stopBlink()
        guard hasKeyFocus, window != nil else { return }
        blinkTimer = Timer.scheduledTimer(timeInterval: 0.55, target: self, selector: #selector(blink), userInfo: nil, repeats: true)
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        caretView.alpha = 1
    }

    @objc private func blink() {
        caretView.alpha = caretView.alpha > 0.5 ? 0 : 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopBlink() } else if hasKeyFocus { restartBlink() }
    }

    // MARK: Pointer

    func pointerDown(_ event: PointerEvent) -> Bool {
        guard event.button == .left else { return false }
        let wasFocused = hasKeyFocus
        DeskSession.shared.desktop?.setKeyFocus(self)
        if !wasFocused && selectsAllOnFocus {
            selectAll()
            return true
        }
        if event.clickCount >= 2 {
            selectAll()
            return true
        }
        allSelected = false
        caret = characterIndex(atX: event.location(in: clipView).x + scrollX)
        refresh()
        restartBlink()
        return true
    }

    private func characterIndex(atX x: CGFloat) -> Int {
        var best = 0
        var bestDistance = abs(x)
        var prefix = ""
        for (index, character) in displayText.enumerated() {
            prefix.append(character)
            let distance = abs(width(of: prefix) - x)
            if distance < bestDistance {
                bestDistance = distance
                best = index + 1
            }
        }
        return best
    }

    func cursor(at point: CGPoint) -> CursorKind? { .text }
}

// MARK: - Slider

final class DeskSlider: UIView, PointerTarget, CursorProvider {
    var value: Double = 0 { didSet { setNeedsLayout() } }
    var onChange: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    private(set) var isDragging = false

    private let track = UIView()
    private let fill = UIView()
    private let knob = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = UIColor(white: 1, alpha: 0.18)
        fill.backgroundColor = Theme.accent
        knob.backgroundColor = .white
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.3
        knob.layer.shadowRadius = 2
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        for view in [track, fill, knob] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var knobSize: CGFloat { Theme.s(14) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let trackHeight = Theme.s(4)
        let inset = knobSize / 2
        let width = max(0, bounds.width - inset * 2)
        let clamped = CGFloat(min(max(value, 0), 1))
        track.frame = CGRect(x: inset, y: (bounds.height - trackHeight) / 2, width: width, height: trackHeight)
        track.layer.cornerRadius = trackHeight / 2
        fill.frame = CGRect(x: inset, y: track.frame.minY, width: width * clamped, height: trackHeight)
        fill.layer.cornerRadius = trackHeight / 2
        knob.frame = CGRect(x: inset + width * clamped - knobSize / 2, y: (bounds.height - knobSize) / 2, width: knobSize, height: knobSize)
        knob.layer.cornerRadius = knobSize / 2
    }

    private func update(from event: PointerEvent) {
        let inset = knobSize / 2
        let width = max(1, bounds.width - inset * 2)
        let x = event.location(in: self).x - inset
        value = Double(min(max(x / width, 0), 1))
        onChange?(value)
    }

    func pointerDown(_ event: PointerEvent) -> Bool {
        guard event.button == .left else { return false }
        isDragging = true
        update(from: event)
        return true
    }

    func pointerDragged(_ event: PointerEvent) { update(from: event) }

    func pointerUp(_ event: PointerEvent) {
        isDragging = false
        onCommit?(value)
    }

    func cursor(at point: CGPoint) -> CursorKind? { .hand }
}

// MARK: - Toggle switch

final class DeskToggle: UIView, PointerTarget, CursorProvider {
    var isOn = false { didSet { setNeedsLayout() } }
    var onChange: ((Bool) -> Void)?
    private let knob = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        knob.backgroundColor = .white
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        backgroundColor = isOn ? Theme.accent : UIColor(white: 1, alpha: 0.2)
        let size = bounds.height - Theme.s(4)
        let x = isOn ? bounds.width - size - Theme.s(2) : Theme.s(2)
        knob.frame = CGRect(x: x, y: Theme.s(2), width: size, height: size)
        knob.layer.cornerRadius = size / 2
    }

    func pointerDown(_ event: PointerEvent) -> Bool { event.button == .left }

    func pointerUp(_ event: PointerEvent) {
        guard bounds.insetBy(dx: -8, dy: -8).contains(event.location(in: self)) else { return }
        isOn.toggle()
        UIView.animate(withDuration: 0.15) { self.layoutIfNeeded() }
        onChange?(isOn)
    }

    func cursor(at point: CGPoint) -> CursorKind? { .hand }
}

// MARK: - Segmented control

final class DeskSegmented: UIView {
    var selectedIndex: Int { didSet { updateSelection() } }
    var onChange: ((Int) -> Void)?
    private var buttons: [DeskButton] = []

    init(titles: [String], selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        backgroundColor = Theme.field
        for (index, title) in titles.enumerated() {
            let button = DeskButton(title: title)
            button.fontSize = 12
            button.horizontalPadding = 8
            button.toggledBackground = Theme.accent
            button.onTap = { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.onChange?(index)
            }
            buttons.append(button)
            addSubview(button)
        }
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() { button.isToggled = index == selectedIndex }
    }

    func preferredWidth() -> CGFloat {
        buttons.reduce(Theme.s(4)) { $0 + $1.preferredWidth() + Theme.s(2) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(7)
        let inset = Theme.s(2)
        let widths = buttons.map { $0.preferredWidth() }
        let total = widths.reduce(0, +)
        let extra = max(0, (bounds.width - inset * 2 - total) / CGFloat(max(1, buttons.count)))
        var x = inset
        for (index, button) in buttons.enumerated() {
            let width = widths[index] + extra
            button.frame = CGRect(x: x, y: inset, width: width, height: bounds.height - inset * 2)
            button.cornerRadius = 5
            x += width
        }
    }
}

// MARK: - App icon tile

/// Rounded gradient tile with an SF Symbol or a letter, used for app icons everywhere.
final class IconTileView: UIView {
    struct Style {
        var symbol: String?
        var letter: String?
        var colors: [UIColor]
        var foreground: UIColor = .white
    }

    var style: Style { didSet { apply() } }
    private let gradient = CAGradientLayer()
    private let imageView = UIImageView()
    private let letterLabel = UILabel()
    private var renderedHeight: CGFloat = 0

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        imageView.contentMode = .center
        addSubview(imageView)
        letterLabel.textAlignment = .center
        addSubview(letterLabel)
        layer.masksToBounds = true
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func apply() {
        gradient.colors = style.colors.map { $0.cgColor }
        imageView.tintColor = style.foreground
        letterLabel.textColor = style.foreground
        renderedHeight = 0
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height * 0.24
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        guard bounds.height > 0, renderedHeight != bounds.height else { return }
        renderedHeight = bounds.height
        if let symbol = style.symbol {
            let configuration = UIImage.SymbolConfiguration(pointSize: bounds.height * 0.44, weight: .semibold)
            imageView.image = UIImage(systemName: symbol, withConfiguration: configuration)
            imageView.isHidden = false
            letterLabel.isHidden = true
        } else {
            imageView.isHidden = true
            letterLabel.isHidden = false
            letterLabel.text = style.letter
            letterLabel.font = .systemFont(ofSize: bounds.height * 0.5, weight: .bold)
        }
        imageView.frame = bounds
        letterLabel.frame = bounds
    }
}

// MARK: - List

struct DeskListItem {
    var title: String
    var subtitle: String?
    var detail: String?
    var symbol: String
    var tint: UIColor
}

/// Vertical list with selection, hover, double-click and context menus.
final class DeskListView: UIScrollView, PointerTarget, HoverTarget {
    var activatesOnSingleClick = false
    private var pressedIndex: Int?
    var items: [DeskListItem] = [] { didSet { rebuild() } }
    var selectedIndex: Int? { didSet { updateRows() } }
    var rowHeight: CGFloat = 34 { didSet { setNeedsLayout() } }
    var showsDetail = true
    var onSelect: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onContextMenu: ((Int?, PointerEvent) -> Void)?

    private var rows: [DeskListRow] = []
    private var hoverIndex: Int?
    private let emptyLabel = UILabel()
    var emptyText: String = "" { didSet { emptyLabel.text = emptyText } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        contentInsetAdjustmentBehavior = .never
        indicatorStyle = .white
        emptyLabel.textColor = Theme.tertiaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.map { item in
            let row = DeskListRow()
            row.item = item
            row.showsDetail = showsDetail
            addSubview(row)
            return row
        }
        if let selected = selectedIndex, selected >= items.count { selectedIndex = nil }
        hoverIndex = nil
        emptyLabel.isHidden = !items.isEmpty
        updateRows()
        setNeedsLayout()
    }

    private func updateRows() {
        for (index, row) in rows.enumerated() {
            row.state = index == selectedIndex ? .selected : (index == hoverIndex ? .hovered : .normal)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Theme.s(rowHeight)
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: Theme.s(4), y: CGFloat(index) * height + Theme.s(4), width: bounds.width - Theme.s(8), height: height)
        }
        contentSize = CGSize(width: bounds.width, height: CGFloat(rows.count) * height + Theme.s(8))
        emptyLabel.font = Theme.font(13)
        emptyLabel.frame = CGRect(x: Theme.s(16), y: Theme.s(24), width: bounds.width - Theme.s(32), height: Theme.s(60))
    }

    func index(at point: CGPoint) -> Int? {
        let height = Theme.s(rowHeight)
        guard height > 0 else { return nil }
        let index = Int(floor((point.y - Theme.s(4)) / height))
        return items.indices.contains(index) ? index : nil
    }

    func scrollToRow(_ index: Int) {
        let height = Theme.s(rowHeight)
        scrollRectToVisible(CGRect(x: 0, y: CGFloat(index) * height, width: 1, height: height + Theme.s(8)), animated: false)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max((selectedIndex ?? (delta > 0 ? -1 : items.count)) + delta, 0), items.count - 1)
        selectedIndex = next
        scrollToRow(next)
        onSelect?(next)
    }

    func pointerDown(_ event: PointerEvent) -> Bool {
        let index = self.index(at: event.location(in: self))
        pressedIndex = event.button == .left ? index : nil
        if event.button == .right {
            if let index {
                selectedIndex = index
                onSelect?(index)
            }
            onContextMenu?(index, event)
            return true
        }
        guard event.button == .left else { return false }
        if let index {
            selectedIndex = index
            onSelect?(index)
            if !activatesOnSingleClick && event.clickCount == 2 { onActivate?(index) }
        } else {
            selectedIndex = nil
        }
        return true
    }

    func pointerUp(_ event: PointerEvent) {
        defer { pressedIndex = nil }
        guard activatesOnSingleClick, event.button == .left, event.clickCount == 1,
              let index = pressedIndex, self.index(at: event.location(in: self)) == index,
              items.indices.contains(index) else { return }
        onActivate?(index)
    }

    func pointerMoved(_ event: PointerEvent) {
        let index = self.index(at: event.location(in: self))
        if index != hoverIndex {
            hoverIndex = index
            updateRows()
        }
    }

    func pointerExited() {
        hoverIndex = nil
        updateRows()
    }
}

final class DeskListRow: UIView {
    enum State { case normal, hovered, selected }

    var item: DeskListItem? { didSet { apply() } }
    var showsDetail = true
    var state: State = .normal { didSet { updateBackground() } }

    private let tile = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        tile.contentMode = .center
        titleLabel.textColor = Theme.text
        subtitleLabel.textColor = Theme.secondaryText
        detailLabel.textColor = Theme.secondaryText
        detailLabel.textAlignment = .right
        for view in [tile, titleLabel, subtitleLabel, detailLabel] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func apply() {
        titleLabel.text = item?.title
        subtitleLabel.text = item?.subtitle
        detailLabel.text = item?.detail
        tile.tintColor = item?.tint
        setNeedsLayout()
    }

    private func updateBackground() {
        switch state {
        case .normal: backgroundColor = .clear
        case .hovered: backgroundColor = Theme.hover
        case .selected: backgroundColor = Theme.selection
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(5)
        let height = bounds.height
        let iconSize = height * 0.62
        if let symbol = item?.symbol {
            tile.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSize * 0.62, weight: .medium))
        }
        tile.frame = CGRect(x: Theme.s(8), y: (height - iconSize) / 2, width: iconSize, height: iconSize)
        let textX = tile.frame.maxX + Theme.s(10)
        let hasDetail = showsDetail && !(item?.detail ?? "").isEmpty
        let detailWidth: CGFloat = hasDetail ? min(Theme.s(190), bounds.width * 0.4) : 0
        detailLabel.isHidden = !hasDetail
        detailLabel.font = Theme.font(11.5)
        detailLabel.frame = CGRect(x: bounds.width - detailWidth - Theme.s(10), y: 0, width: detailWidth, height: height)
        let textWidth = max(0, bounds.width - textX - detailWidth - Theme.s(16))
        titleLabel.font = Theme.font(13)
        subtitleLabel.font = Theme.font(11)
        if (item?.subtitle ?? "").isEmpty {
            subtitleLabel.isHidden = true
            titleLabel.frame = CGRect(x: textX, y: 0, width: textWidth, height: height)
        } else {
            subtitleLabel.isHidden = false
            let titleHeight = ceil(titleLabel.font.lineHeight)
            let subtitleHeight = ceil(subtitleLabel.font.lineHeight)
            let top = (height - titleHeight - subtitleHeight) / 2
            titleLabel.frame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
            subtitleLabel.frame = CGRect(x: textX, y: top + titleHeight, width: textWidth, height: subtitleHeight)
        }
    }
}
