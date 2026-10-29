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
    var onInputLanguageChange: (() -> Void)?
    var onToggleInputLanguage: (() -> Void)?

    enum InputLanguage: String {
        case korean = "ko", english = "en"
        var title: String { self == .korean ? "한국어" : "영어" }
        var next: InputLanguage { self == .korean ? .english : .korean }
        init?(primaryLanguage: String?) {
            guard let prefix = primaryLanguage?.split(separator: "-").first,
                  let value = InputLanguage(rawValue: String(prefix)) else { return nil }
            self = value
        }
    }
    private var preferredLanguage: InputLanguage?
    private var switchingInputLanguage = false

    var inputLanguage: InputLanguage? {
        preferredLanguage ?? InputLanguage(primaryLanguage: super.textInputMode?.primaryLanguage)
    }

    override var textInputMode: UITextInputMode? {
        if let preferredLanguage,
           let mode = Self.availableMode(for: preferredLanguage) { return mode }
        return super.textInputMode
    }

    override var textInputContextIdentifier: String? {
        "PocketDesk.keyboard.\(preferredLanguage?.rawValue ?? "system")"
    }

    static func availableMode(for language: InputLanguage) -> UITextInputMode? {
        UITextInputMode.activeInputModes.first { InputLanguage(primaryLanguage: $0.primaryLanguage) == language }
    }

    private var forwarded = ""
    private var cachedCommands: [UIKeyCommand]?
    private var handledHardwarePresses = Set<UIPress>()
    private var panelComposer = HangulComposer()

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
        NotificationCenter.default.addObserver(self, selector: #selector(systemInputLanguageChanged),
            name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Commit the IME before changing responders. Clearing the local buffer must not delete
    /// the text that has already reached the browser, address field or remote computer.
    func commitComposition() {
        if markedTextRange != nil { unmarkText() }
        textViewDidChange(self)
        clearBuffer()
    }

    @discardableResult
    func selectInputLanguage(_ language: InputLanguage) -> Bool {
        guard Self.availableMode(for: language) != nil else { return false }
        switchingInputLanguage = true
        commitComposition()
        stickyModifiers = []
        preferredLanguage = language
        if isFirstResponder {
            // A new editing session makes UIKit apply textInputMode to hardware keyboards too.
            UIView.performWithoutAnimation {
                resignFirstResponder()
                becomeFirstResponder()
                reloadInputViews()
            }
        }
        switchingInputLanguage = false
        onInputLanguageChange?()
        return true
    }

    @objc private func systemInputLanguageChanged() {
        guard isFirstResponder, !switchingInputLanguage else { return }
        // The globe key and iOS's own language shortcuts remain usable.
        preferredLanguage = InputLanguage(primaryLanguage: super.textInputMode?.primaryLanguage)
        onInputLanguageChange?()
    }

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
        panelComposer.reset()
    }

    func insertPanelText(_ value: String, language: InputLanguage) {
        guard language == .korean, value.count == 1, let jamo = value.first, HangulComposer.isJamo(jamo) else {
            commitComposition()
            DeskSession.shared.insertText(value)
            return
        }
        if panelComposer.isEmpty { commitComposition() }
        let old = panelComposer.text
        panelComposer.append(jamo)
        replacePanelComposition(old: old)
        if panelComposer.text.count > 100 { panelComposer.reset() }
    }

    func deletePanelBackward() {
        guard !panelComposer.isEmpty else { commitComposition(); DeskSession.shared.deleteBackward(); return }
        let old = panelComposer.text
        panelComposer.delete()
        replacePanelComposition(old: old)
    }

    private func replacePanelComposition(old: String) {
        let before = Array(old), after = Array(panelComposer.text)
        var prefix = 0
        while prefix < before.count && prefix < after.count && before[prefix] == after[prefix] { prefix += 1 }
        for _ in prefix..<before.count { DeskSession.shared.deleteBackward() }
        let suffix = String(after.dropFirst(prefix))
        if !suffix.isEmpty { DeskSession.shared.insertText(suffix) }
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

    /// Hardware HID distinguishes Backspace from forward Delete; UITextView may otherwise
    /// consume Backspace against its empty IME buffer without forwarding it to the desktop.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        for press in presses {
            guard let key = press.key,
                  handleHardwareKey(key.keyCode, modifiers: key.modifierFlags) else { continue }
            handledHardwarePresses.insert(press)
            unhandled.remove(press)
        }
        if !unhandled.isEmpty {
            if unhandled.contains(where: { press in
                guard let code = press.key?.keyCode.rawValue else { return false }
                return !(0xE0...0xE7).contains(code) && code != UIKeyboardHIDUsage.keyboardCapsLock.rawValue
            }) { panelComposer.reset() }
            super.pressesBegan(unhandled, with: event)
        }
    }

    /// Use physical letter positions so the selected language controls actual Bluetooth
    /// input, even if the hardware keyboard's native layout has not refreshed yet.
    @discardableResult
    func handleHardwareKey(_ code: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
        if code == .keyboardLANG1 || (code == .keyboardSpacebar && modifiers.intersection([.control, .alternate, .command, .shift]) == .control) {
            if let onToggleInputLanguage { onToggleInputLanguage() }
            else { _ = selectInputLanguage(inputLanguage?.next ?? .korean) }
            return true
        }
        guard markedTextRange == nil else { return false }
        if let deletion = Self.deletionKey(for: code) {
            if deletion == .backspace && modifiers.intersection([.control, .alternate, .command]).isEmpty && !panelComposer.isEmpty {
                deletePanelBackward()
            } else {
                commitComposition()
                DeskSession.shared.specialKey(deletion, modifiers: KeyModifiers(flags: modifiers))
            }
            return true
        }
        guard modifiers.intersection([.control, .alternate, .command]).isEmpty,
              let language = inputLanguage,
              let letter = Self.hardwareLetter(code, modifiers: modifiers, language: language) else { return false }
        insertPanelText(letter, language: language)
        return true
    }

    static func hardwareLetter(_ code: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags, language: InputLanguage) -> String? {
        let index = Int(code.rawValue) - Int(UIKeyboardHIDUsage.keyboardA.rawValue)
        guard (0..<26).contains(index) else { return nil }
        if language == .english {
            let upper = modifiers.contains(.shift) != modifiers.contains(.alphaShift)
            return String(Array(upper ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "abcdefghijklmnopqrstuvwxyz")[index])
        }
        let shifted = modifiers.contains(.shift)
        return String(Array(shifted ? "ㅁㅠㅊㅇㄸㄹㅎㅗㅑㅓㅏㅣㅡㅜㅒㅖㅃㄲㄴㅆㅕㅍㅉㅌㅛㅋ" : "ㅁㅠㅊㅇㄷㄹㅎㅗㅑㅓㅏㅣㅡㅜㅐㅔㅂㄱㄴㅅㅕㅍㅈㅌㅛㅋ")[index])
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.subtracting(handledHardwarePresses)
        handledHardwarePresses.subtract(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.subtracting(handledHardwarePresses)
        handledHardwarePresses.subtract(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    static func deletionKey(for code: UIKeyboardHIDUsage) -> SpecialKey? {
        switch code {
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardDeleteForward: return .deleteForward
        default: return nil
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
        let languageCommand = UIKeyCommand(input: " ", modifierFlags: .control, action: #selector(handleLanguageCommand))
        languageCommand.wantsPriorityOverSystemBehavior = true
        // Let the Korean/other IME consume deletion and candidate-navigation keys while composing.
        if markedTextRange != nil { return (super.keyCommands ?? []) + [languageCommand] }
        if let cachedCommands { return cachedCommands }
        var commands: [UIKeyCommand] = [languageCommand]
        func add(_ input: String, _ flags: UIKeyModifierFlags) {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(handleKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        let navigation = [
            UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
            UIKeyCommand.inputHome, UIKeyCommand.inputEnd, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
            UIKeyCommand.inputEscape,
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
        case UIKeyCommand.inputDelete, "\u{8}": return .backspace
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

    @objc private func handleLanguageCommand() {
        _ = handleHardwareKey(.keyboardSpacebar, modifiers: .control)
    }
}

/// Extra keys above the on-screen keyboard: Esc, Tab, Ctrl, arrows and "hide".
final class KeyboardAccessoryBar: UIInputView {
    var onHide: (() -> Void)?
    var onToggleLanguage: (() -> Void)?
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
        let language = makeKey(title: "한/영") { [weak self] in self?.onToggleLanguage?() }
        language.accessibilityIdentifier = "keyboard.language.accessory"
        language.accessibilityLabel = "한영 전환"
        stack.addArrangedSubview(language)
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
