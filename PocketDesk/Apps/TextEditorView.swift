import UIKit

/// Multi-line text editor driven by the desktop's key focus. A TextKit 1 `UITextView` does the
/// layout and drawing; caret, selection, editing and undo live here because a view on the
/// external display can never become first responder.
final class TextEditorView: UIView, KeyInputTarget, PointerTarget, CursorProvider {
    let textView = UITextView(usingTextLayoutManager: false)
    var onChange: (() -> Void)?
    var fontSize: CGFloat = 15 { didSet { applyAttributes() } }
    var isMonospaced = false { didSet { applyAttributes() } }
    var isEditable = true
    var inputDescription: String = "텍스트 편집"
    var placeholder: String = "" { didSet { placeholderLabel.text = placeholder } }

    private struct Edit {
        var range: NSRange
        var oldText: String
        var newText: String
        var time: CFTimeInterval
    }

    private let caretView = UIView()
    private let placeholderLabel = UILabel()
    private var selectionViews: [UIView] = []
    private var anchor = 0
    private var focus = 0
    private var hasKeyFocus = false
    private var desiredX: CGFloat?
    private var isDragging = false
    private var blinkTimer: Timer?
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private var appliedScale: CGFloat = 0

    var text: String { textView.textStorage.string }
    var selection: NSRange { NSRange(location: min(anchor, focus), length: abs(focus - anchor)) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.indicatorStyle = .white
        textView.alwaysBounceVertical = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.layoutManager.allowsNonContiguousLayout = false
        addSubview(textView)
        caretView.backgroundColor = Theme.accent
        caretView.isUserInteractionEnabled = false
        caretView.isHidden = true
        textView.addSubview(caretView)
        placeholderLabel.textColor = Theme.tertiaryText
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Text & attributes

    private var editorFont: UIFont {
        isMonospaced ? Theme.monoFont(fontSize) : Theme.font(fontSize)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Theme.s(3)
        return [.font: editorFont, .foregroundColor: Theme.text, .paragraphStyle: paragraph]
    }

    func setText(_ string: String) {
        textView.textStorage.setAttributedString(NSAttributedString(string: string, attributes: attributes))
        anchor = 0
        focus = 0
        undoStack.removeAll()
        redoStack.removeAll()
        textView.contentOffset = .zero
        refreshSelection()
    }

    private func applyAttributes() {
        let storage = textView.textStorage
        storage.beginEditing()
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        refreshSelection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if appliedScale != Theme.scale {
            appliedScale = Theme.scale
            applyAttributes()
        }
        textView.frame = bounds
        let inset = UIEdgeInsets(top: Theme.s(14), left: Theme.s(16), bottom: Theme.s(14), right: Theme.s(16))
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        placeholderLabel.font = editorFont
        placeholderLabel.frame = CGRect(
            x: inset.left + textView.textContainer.lineFragmentPadding, y: inset.top,
            width: max(0, bounds.width - inset.left - inset.right), height: ceil(editorFont.lineHeight)
        )
        refreshSelection()
    }

    // MARK: Geometry (TextKit 1)

    private var layoutManager: NSLayoutManager { textView.layoutManager }
    private var container: NSTextContainer { textView.textContainer }
    private var inset: UIEdgeInsets { textView.textContainerInset }
    private var length: Int { textView.textStorage.length }

    /// Character index nearest to `point` (in the text view's content coordinates).
    func characterIndex(at point: CGPoint) -> Int {
        guard length > 0 else { return 0 }
        layoutManager.ensureLayout(for: container)
        let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        if local.y < 0 { return 0 }
        if local.y >= layoutManager.usedRect(for: container).maxY { return length }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < length else { return length }
        let string = text as NSString
        let composed = string.rangeOfComposedCharacterSequence(at: index)
        if fraction > 0.5 && string.character(at: index) != 10 {
            return min(NSMaxRange(composed), length)
        }
        return composed.location
    }

    func caretRect(at index: Int) -> CGRect {
        let width = max(1.5, Theme.s(2))
        let lineHeight = ceil(editorFont.lineHeight)
        guard length > 0 else {
            return CGRect(x: inset.left + container.lineFragmentPadding, y: inset.top, width: width, height: lineHeight)
        }
        layoutManager.ensureLayout(for: container)
        let string = text as NSString
        if index >= length {
            if string.character(at: length - 1) == 10 {
                let extra = layoutManager.extraLineFragmentRect
                return CGRect(x: inset.left + extra.minX + container.lineFragmentPadding, y: inset.top + extra.minY, width: width, height: lineHeight)
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            return CGRect(x: inset.left + rect.maxX, y: inset.top + line.minY, width: width, height: min(line.height, lineHeight))
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return CGRect(x: inset.left + rect.minX, y: inset.top + line.minY, width: width, height: min(line.height, lineHeight))
    }

    private func refreshSelection() {
        selectionViews.forEach { $0.removeFromSuperview() }
        selectionViews.removeAll()
        let range = selection
        if range.length > 0 && length > 0 {
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let offset = CGPoint(x: inset.left, y: inset.top)
            var rects: [CGRect] = []
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                rects.append(rect.offsetBy(dx: offset.x, dy: offset.y))
            }
            for rect in rects {
                let view = UIView(frame: rect)
                view.backgroundColor = Theme.selection
                view.isUserInteractionEnabled = false
                textView.insertSubview(view, at: 0)
                selectionViews.append(view)
            }
        }
        caretView.frame = caretRect(at: focus)
        caretView.isHidden = !hasKeyFocus || range.length > 0
        textView.bringSubviewToFront(caretView)
        placeholderLabel.isHidden = length > 0
    }

    func scrollCaretVisible() {
        let rect = caretRect(at: focus).insetBy(dx: -Theme.s(4), dy: -Theme.s(12))
        textView.scrollRectToVisible(rect, animated: false)
    }

    private func visualLineRange(at index: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let string = text as NSString
        if index >= length && string.character(at: length - 1) == 10 {
            return NSRange(location: length, length: 0)
        }
        layoutManager.ensureLayout(for: container)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        var lineGlyphs = NSRange(location: 0, length: 0)
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        return layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
    }

    private func visualLineEnd(at index: Int) -> Int {
        let range = visualLineRange(at: index)
        var end = NSMaxRange(range)
        let string = text as NSString
        if end > range.location && end <= string.length && string.character(at: end - 1) == 10 { end -= 1 }
        return end
    }

    private var linesPerPage: Int {
        max(1, Int(textView.bounds.height / max(editorFont.lineHeight + Theme.s(3), 1)) - 1)
    }

    private func verticalIndex(from index: Int, lines: Int) -> Int {
        let caret = caretRect(at: index)
        let x = desiredX ?? caret.midX
        desiredX = x
        let y = caret.midY + CGFloat(lines) * (caret.height + Theme.s(3))
        if y < inset.top { return 0 }
        layoutManager.ensureLayout(for: container)
        if y > inset.top + layoutManager.usedRect(for: container).maxY { return length }
        return characterIndex(at: CGPoint(x: x, y: y))
    }

    private func isWordCharacter(at index: Int) -> Bool {
        let string = text as NSString
        guard index >= 0, index < string.length, let scalar = UnicodeScalar(string.character(at: index)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private func wordBoundary(from index: Int, forward: Bool) -> Int {
        var i = index
        if forward {
            while i < length && !isWordCharacter(at: i) { i += 1 }
            while i < length && isWordCharacter(at: i) { i += 1 }
        } else {
            while i > 0 && !isWordCharacter(at: i - 1) { i -= 1 }
            while i > 0 && isWordCharacter(at: i - 1) { i -= 1 }
        }
        return i
    }

    private func wordRange(at index: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let i = min(index, length - 1)
        guard isWordCharacter(at: i) else { return (text as NSString).rangeOfComposedCharacterSequence(at: i) }
        var start = i
        while start > 0 && isWordCharacter(at: start - 1) { start -= 1 }
        var end = i
        while end < length && isWordCharacter(at: end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Editing

    private func clamped(_ range: NSRange) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    func replace(_ range: NSRange, with string: String, recordUndo: Bool = true, coalesce: Bool = false) {
        guard isEditable else { return }
        let target = clamped(range)
        let old = (text as NSString).substring(with: target)
        if old.isEmpty && string.isEmpty { return }
        textView.textStorage.replaceCharacters(in: target, with: NSAttributedString(string: string, attributes: attributes))
        let newRange = NSRange(location: target.location, length: (string as NSString).length)
        if recordUndo {
            pushUndo(Edit(range: newRange, oldText: old, newText: string, time: CACurrentMediaTime()), coalesce: coalesce)
            redoStack.removeAll()
        }
        anchor = NSMaxRange(newRange)
        focus = anchor
        desiredX = nil
        refreshSelection()
        scrollCaretVisible()
        restartBlink()
        onChange?()
    }

    private func pushUndo(_ edit: Edit, coalesce: Bool) {
        if coalesce, var last = undoStack.last, edit.time - last.time < 1.2, last.oldText.isEmpty, edit.oldText.isEmpty,
           NSMaxRange(last.range) == edit.range.location, !edit.newText.contains("\n") {
            last.range.length += edit.range.length
            last.newText += edit.newText
            last.time = edit.time
            undoStack[undoStack.count - 1] = last
            return
        }
        undoStack.append(edit)
        if undoStack.count > 400 { undoStack.removeFirst(undoStack.count - 400) }
    }

    /// Reverts `edit` and returns the edit that re-applies it.
    private func revert(_ edit: Edit) -> Edit {
        let target = clamped(edit.range)
        replace(target, with: edit.oldText, recordUndo: false)
        return Edit(range: NSRange(location: target.location, length: (edit.oldText as NSString).length),
                    oldText: edit.newText, newText: edit.oldText, time: 0)
    }

    func undo() {
        if let edit = undoStack.popLast() { redoStack.append(revert(edit)) }
    }

    func redo() {
        if let edit = redoStack.popLast() { undoStack.append(revert(edit)) }
    }

    func selectEverything() {
        anchor = 0
        focus = length
        refreshSelection()
    }

    func copySelection() {
        let range = selection
        guard range.length > 0 else { return }
        UIPasteboard.general.string = (text as NSString).substring(with: range)
    }

    func cutSelection() {
        guard isEditable, selection.length > 0 else { return }
        copySelection()
        replace(selection, with: "")
    }

    func pasteText() {
        guard isEditable, let string = UIPasteboard.general.string else { return }
        replace(selection, with: string)
    }

    // MARK: KeyInputTarget

    var acceptsTextInput: Bool { isEditable }

    func insertText(_ string: String) {
        replace(selection, with: string, coalesce: (string as NSString).length <= 2)
    }

    func deleteBackward() {
        let range = selection
        if range.length > 0 {
            replace(range, with: "")
        } else if range.location > 0 {
            replace((text as NSString).rangeOfComposedCharacterSequence(at: range.location - 1), with: "")
        }
    }

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        switch key {
        case .enter:
            insertText("\n")
            return
        case .tab:
            insertText("\t")
            return
        case .backspace:
            deleteBackward()
            return
        case .deleteForward:
            if selection.length > 0 {
                replace(selection, with: "")
            } else if selection.location < length {
                replace((text as NSString).rangeOfComposedCharacterSequence(at: selection.location), with: "")
            }
            return
        case .escape:
            anchor = focus
            refreshSelection()
            return
        default:
            break
        }
        let vertical = key == .up || key == .down || key == .pageUp || key == .pageDown
        if !vertical { desiredX = nil }
        let extend = modifiers.contains(.shift)
        let string = text as NSString
        let word = modifiers.contains(.option) || (modifiers.contains(.control) && !modifiers.contains(.command))
        let line = modifiers.contains(.command)
        var target: Int
        switch key {
        case .left:
            if !extend && selection.length > 0 {
                target = selection.location
            } else if line {
                target = visualLineRange(at: focus).location
            } else if word {
                target = wordBoundary(from: focus, forward: false)
            } else {
                target = focus > 0 ? string.rangeOfComposedCharacterSequence(at: focus - 1).location : 0
            }
        case .right:
            if !extend && selection.length > 0 {
                target = NSMaxRange(selection)
            } else if line {
                target = visualLineEnd(at: focus)
            } else if word {
                target = wordBoundary(from: focus, forward: true)
            } else {
                target = focus < length ? NSMaxRange(string.rangeOfComposedCharacterSequence(at: focus)) : length
            }
        case .up:
            target = modifiers.hasShortcutKey ? 0 : verticalIndex(from: focus, lines: -1)
        case .down:
            target = modifiers.hasShortcutKey ? length : verticalIndex(from: focus, lines: 1)
        case .pageUp:
            target = verticalIndex(from: focus, lines: -linesPerPage)
        case .pageDown:
            target = verticalIndex(from: focus, lines: linesPerPage)
        case .home:
            target = modifiers.hasShortcutKey ? 0 : visualLineRange(at: focus).location
        case .end:
            target = modifiers.hasShortcutKey ? length : visualLineEnd(at: focus)
        default:
            return
        }
        focus = min(max(0, target), length)
        if !extend { anchor = focus }
        refreshSelection()
        scrollCaretVisible()
        restartBlink()
    }

    func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "a": selectEverything()
        case "c": copySelection()
        case "x": cutSelection()
        case "v": pasteText()
        case "z": if modifiers.contains(.shift) { redo() } else { undo() }
        case "y": redo()
        default: return false
        }
        return true
    }

    func keyFocusChanged(_ focused: Bool) {
        hasKeyFocus = focused
        if focused { restartBlink() } else { stopBlink() }
        refreshSelection()
    }

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
        guard event.button == .left || event.button == .right else { return false }
        DeskSession.shared.desktop?.setKeyFocus(self)
        let index = characterIndex(at: event.location(in: textView))
        if event.button == .right {
            if selection.length == 0 || !NSLocationInRange(index, selection) {
                anchor = index
                focus = index
            }
            refreshSelection()
            showContextMenu(at: event.location)
            return true
        }
        desiredX = nil
        switch event.clickCount {
        case 2:
            let range = wordRange(at: index)
            anchor = range.location
            focus = NSMaxRange(range)
        case 3...:
            let range = (text as NSString).paragraphRange(for: NSRange(location: min(index, max(0, length - 1)), length: 0))
            anchor = range.location
            focus = NSMaxRange(range)
        default:
            if event.modifiers.contains(.shift) {
                focus = index
            } else {
                anchor = index
                focus = index
            }
        }
        // Dragging after a double-click extends the selection from the word's start.
        isDragging = event.clickCount <= 2
        refreshSelection()
        restartBlink()
        return true
    }

    func pointerDragged(_ event: PointerEvent) {
        guard isDragging else { return }
        let point = event.location(in: textView)
        focus = characterIndex(at: point)
        let visible = textView.bounds
        if point.y < visible.minY {
            _ = textView.deskScroll(by: CGPoint(x: 0, y: -Theme.s(18)))
        } else if point.y > visible.maxY {
            _ = textView.deskScroll(by: CGPoint(x: 0, y: Theme.s(18)))
        }
        refreshSelection()
    }

    func pointerUp(_ event: PointerEvent) {
        isDragging = false
    }

    func cursor(at point: CGPoint) -> CursorKind? { .text }

    private func showContextMenu(at point: CGPoint) {
        let hasSelection = selection.length > 0
        let items: [MenuItem] = [
            MenuItem(title: "잘라내기", symbol: "scissors", shortcut: "⌘X", isEnabled: hasSelection && isEditable) { [weak self] in self?.cutSelection() },
            MenuItem(title: "복사", symbol: "doc.on.doc", shortcut: "⌘C", isEnabled: hasSelection) { [weak self] in self?.copySelection() },
            MenuItem(title: "붙여넣기", symbol: "doc.on.clipboard", shortcut: "⌘V", isEnabled: isEditable && UIPasteboard.general.hasStrings) { [weak self] in self?.pasteText() },
            .separator,
            MenuItem(title: "모두 선택", symbol: "text.badge.checkmark", shortcut: "⌘A") { [weak self] in self?.selectEverything() },
            MenuItem(title: "실행 취소", symbol: "arrow.uturn.backward", shortcut: "⌘Z", isEnabled: !undoStack.isEmpty) { [weak self] in self?.undo() },
            MenuItem(title: "다시 실행", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", isEnabled: !redoStack.isEmpty) { [weak self] in self?.redo() },
        ]
        DeskSession.shared.desktop?.showContextMenu(items, at: point)
    }
}
