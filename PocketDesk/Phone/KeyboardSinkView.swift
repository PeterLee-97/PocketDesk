import UIKit

/// An invisible text view on the phone that owns keyboard focus (soft keyboard or Bluetooth
/// keyboard) and forwards what is typed to the desktop.
///
/// Text is forwarded as a diff of the buffer, so iOS input methods keep working: Korean
/// composition, for example, arrives as "ㅎ" → (delete, "하") → (delete, "한"). The buffer is
/// cleared only at safe points (after whitespace/punctuation) so composition is never cut off.
final class KeyboardSinkView: UITextView, UITextViewDelegate {
    /// One-shot modifiers from the accessory bar's Ctrl button.
    var stickyModifiers: KeyModifiers = [] { didSet { onStickyChange?() } }
    var onStickyChange: (() -> Void)?

    private var forwarded = ""
    private var cachedCommands: [UIKeyCommand]?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardAppearance = .dark
        if #available(iOS 17.0, *) { inlinePredictionType = .no }
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Text → desktop

    func textViewDidChange(_ textView: UITextView) {
        let current = text ?? ""
        let old = Array(forwarded)
        let new = Array(current)
        var common = 0
        while common < old.count && common < new.count && old[common] == new[common] { common += 1 }
        let deletions = old.count - common
        let insertion = String(new[common...])

        if !stickyModifiers.isEmpty && deletions == 0 && insertion.count == 1 {
            // Ctrl + key typed with the on-screen keyboard.
            let modifiers = stickyModifiers
            stickyModifiers = []
            text = String(current.dropLast())
            forwarded = text ?? ""
            DeskSession.shared.shortcut(insertion.lowercased(), modifiers: modifiers)
            return
        }

        forwarded = current
        for _ in 0..<deletions { DeskSession.shared.deleteBackward() }
        if !insertion.isEmpty { DeskSession.shared.insertText(insertion) }
        resetIfSafe()
    }

    private func resetIfSafe() {
        guard markedTextRange == nil, let last = (text ?? "").last else { return }
        if last.isWhitespace || last.isPunctuation || (text ?? "").count > 200 {
            clearBuffer()
        }
    }

    func clearBuffer() {
        text = ""
        forwarded = ""
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
        if markedTextRange != nil { return true }
        if replacement == "\n" {
            clearBuffer()
            DeskSession.shared.specialKey(.enter, modifiers: [])
            return false
        }
        if replacement == "\t" {
            clearBuffer()
            DeskSession.shared.specialKey(.tab, modifiers: [])
            return false
        }
        return true
    }

    override func deleteBackward() {
        if (text ?? "").isEmpty {
            DeskSession.shared.deleteBackward()
        } else {
            super.deleteBackward()
        }
    }

    // MARK: Edit actions (menu / shortcut bar) → desktop

    override func paste(_ sender: Any?) {
        DeskSession.shared.shortcut("v", modifiers: .command)
    }

    override func copy(_ sender: Any?) {
        DeskSession.shared.shortcut("c", modifiers: .command)
    }

    override func cut(_ sender: Any?) {
        DeskSession.shared.shortcut("x", modifiers: .command)
    }

    override func selectAll(_ sender: Any?) {
        DeskSession.shared.shortcut("a", modifiers: .command)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let forwardedActions: [Selector] = [
            #selector(UIResponderStandardEditActions.paste(_:)),
            #selector(UIResponderStandardEditActions.copy(_:)),
            #selector(UIResponderStandardEditActions.cut(_:)),
            #selector(UIResponderStandardEditActions.selectAll(_:)),
        ]
        if forwardedActions.contains(action) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: Hardware keyboard: special keys and shortcuts

    override var keyCommands: [UIKeyCommand]? {
        if let cachedCommands { return cachedCommands }
        var commands: [UIKeyCommand] = []
        func add(_ input: String, _ flags: UIKeyModifierFlags) {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(handleKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        let navigation = [
            UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
            UIKeyCommand.inputHome, UIKeyCommand.inputEnd, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
            UIKeyCommand.inputEscape, UIKeyCommand.inputDelete,
        ]
        let navigationModifiers: [UIKeyModifierFlags] = [
            [], .shift, .command, [.command, .shift], .alternate, [.alternate, .shift], .control, [.control, .shift], [.command, .alternate],
        ]
        for input in navigation {
            for flags in navigationModifiers { add(input, flags) }
        }
        // Plain Return/Tab go through the text system; these are the modified variants.
        for flags in [UIKeyModifierFlags.shift, .command, .control, .alternate, [.command, .shift]] { add("\r", flags) }
        for flags in [UIKeyModifierFlags.shift, .control, [.control, .shift], .alternate, [.alternate, .shift], .command, [.command, .shift]] { add("\t", flags) }
        let shortcutKeys = "abcdefghijklmnopqrstuvwxyz0123456789[]=-,./;'"
        for character in shortcutKeys {
            for flags in [UIKeyModifierFlags.command, [.command, .shift], .control, [.control, .shift]] {
                add(String(character), flags)
            }
        }
        cachedCommands = commands
        return commands
    }

    static func specialKey(for input: String) -> SpecialKey? {
        switch input {
        case UIKeyCommand.inputUpArrow: return .up
        case UIKeyCommand.inputDownArrow: return .down
        case UIKeyCommand.inputLeftArrow: return .left
        case UIKeyCommand.inputRightArrow: return .right
        case UIKeyCommand.inputHome: return .home
        case UIKeyCommand.inputEnd: return .end
        case UIKeyCommand.inputPageUp: return .pageUp
        case UIKeyCommand.inputPageDown: return .pageDown
        case UIKeyCommand.inputEscape: return .escape
        case UIKeyCommand.inputDelete: return .deleteForward
        case "\r": return .enter
        case "\t": return .tab
        default: return nil
        }
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        let modifiers = KeyModifiers(flags: command.modifierFlags)
        if let special = KeyboardSinkView.specialKey(for: input) {
            if markedTextRange != nil { unmarkText() }
            clearBuffer()
            DeskSession.shared.specialKey(special, modifiers: modifiers)
        } else {
            DeskSession.shared.shortcut(input.lowercased(), modifiers: modifiers)
        }
    }
}

/// Extra keys above the on-screen keyboard: Esc, Tab, Ctrl, arrows and "hide".
final class KeyboardAccessoryBar: UIInputView {
    var onHide: (() -> Void)?
    private weak var sink: KeyboardSinkView?
    private let stack = UIStackView()
    private var controlButton: UIButton?
    private var repeatTimer: Timer?
    private var repeatingKey: SpecialKey?

    init(sink: KeyboardSinkView) {
        self.sink = sink
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalToConstant: 38),
        ])
        stack.addArrangedSubview(makeKey(title: "Esc") { DeskSession.shared.specialKey(.escape, modifiers: []) })
        stack.addArrangedSubview(makeKey(title: "Tab") { DeskSession.shared.specialKey(.tab, modifiers: []) })
        let control = makeKey(title: "Ctrl") { [weak self] in self?.toggleControl() }
        controlButton = control
        stack.addArrangedSubview(control)
        for (symbol, key) in [("arrow.left", SpecialKey.left), ("arrow.up", .up), ("arrow.down", .down), ("arrow.right", .right)] {
            stack.addArrangedSubview(makeRepeatingKey(symbol: symbol, key: key))
        }
        stack.addArrangedSubview(makeKey(symbol: "keyboard.chevron.compact.down") { [weak self] in self?.onHide?() })
        sink.onStickyChange = { [weak self] in self?.updateControl() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configuration(title: String?, symbol: String?) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor(white: 1, alpha: 0.18)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .medium
        configuration.title = title
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        return configuration
    }

    private func makeKey(title: String? = nil, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        UIButton(configuration: configuration(title: title, symbol: symbol), primaryAction: UIAction { _ in action() })
    }

    private func makeRepeatingKey(symbol: String, key: SpecialKey) -> UIButton {
        let button = UIButton(configuration: configuration(title: nil, symbol: symbol))
        button.tag = KeyboardAccessoryBar.tags[key] ?? 0
        button.addTarget(self, action: #selector(repeatStart(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(repeatStop), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    private static let tags: [SpecialKey: Int] = [.left: 1, .up: 2, .down: 3, .right: 4]

    @objc private func repeatStart(_ sender: UIButton) {
        guard let key = KeyboardAccessoryBar.tags.first(where: { $0.value == sender.tag })?.key else { return }
        repeatingKey = key
        sendRepeatingKey()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(timeInterval: 0.4, target: self, selector: #selector(beginFastRepeat), userInfo: nil, repeats: false)
    }

    @objc private func beginFastRepeat() {
        repeatTimer = Timer.scheduledTimer(timeInterval: 0.06, target: self, selector: #selector(sendRepeatingKey), userInfo: nil, repeats: true)
    }

    @objc private func sendRepeatingKey() {
        guard let key = repeatingKey else { return }
        sink?.clearBuffer()
        DeskSession.shared.specialKey(key, modifiers: sink?.stickyModifiers ?? [])
    }

    @objc private func repeatStop() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingKey = nil
    }

    private func toggleControl() {
        guard let sink else { return }
        sink.stickyModifiers = sink.stickyModifiers.contains(.control) ? [] : [.control]
    }

    private func updateControl() {
        guard let button = controlButton else { return }
        var configuration = button.configuration
        let active = sink?.stickyModifiers.contains(.control) == true
        configuration?.baseBackgroundColor = active ? UIColor(hex: 0x4A8FFF) : UIColor(white: 1, alpha: 0.18)
        button.configuration = configuration
    }
}
