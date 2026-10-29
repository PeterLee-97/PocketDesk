import UIKit

/// A phone keyboard that stays available even when iOS hides its keyboard for Bluetooth input.
final class OnscreenKeyboardView: UIView {
    enum Key: Equatable { case text(String), delete, enter, tab, language, hide }
    var onKey: ((Key) -> Void)?
    var language: KeyboardSinkView.InputLanguage = .english { didSet { if oldValue != language { shifted = false; rebuild() } } }
    private var shifted = false
    private var symbols = false
    private let stack = UIStackView()
    private var deleteTimer: Timer?
    private var deleteRepeated = false
    override var isHidden: Bool {
        didSet { if isHidden { stopDelete(); deleteRepeated = false } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.panel"
        backgroundColor = UIColor(white: 0.06, alpha: 1)
        layer.cornerRadius = 16
        stack.axis = .vertical; stack.spacing = 5; stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ title: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor(white: 0.2, alpha: 1)
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0)
        config.cornerStyle = .small
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { value in
            var result = value; result.font = .systemFont(ofSize: 17, weight: .medium); return result
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityIdentifier = "keyboard.key.\(title)"
        button.accessibilityLabel = title
        return button
    }
    private func row(_ buttons: [UIButton]) {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal; row.spacing = 4; row.distribution = .fillEqually
        stack.addArrangedSubview(row)
    }
    private func characters(_ text: String) -> [UIButton] {
        text.map { character in
            button(String(character)) { [weak self] in
                self?.onKey?(.text(String(character)))
                if self?.shifted == true { self?.shifted = false; self?.rebuild() }
            }
        }
    }
    private func rebuild() {
        stopDelete()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        row(characters(shifted ? "!@#$%^&*()" : "1234567890"))
        if symbols {
            row(characters("-/:;()₩&@\""))
            row(characters("[]{}#%+=_*"))
        } else if language == .korean {
            row(characters(shifted ? "ㅃㅉㄸㄲㅆㅛㅕㅑㅒㅖ" : "ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ"))
            row(characters("ㅁㄴㅇㄹㅎㅗㅓㅏㅣ"))
        } else {
            row(characters(shifted ? "QWERTYUIOP" : "qwertyuiop"))
            row(characters(shifted ? "ASDFGHJKL" : "asdfghjkl"))
        }
        let shift = button("⇧") { [weak self] in self?.shifted.toggle(); self?.rebuild() }
        shift.accessibilityLabel = "Shift"
        let delete = button("⌫") {}
        delete.accessibilityLabel = "글자 지우기"
        delete.addTarget(self, action: #selector(startDelete), for: .touchDown)
        delete.addTarget(self, action: #selector(stopDelete), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // Accessibility/keyboard activation doesn't produce touchDown.
        delete.addAction(UIAction { [weak self] _ in
            if self?.deleteRepeated == false { self?.onKey?(.delete) }
            self?.deleteRepeated = false
        }, for: .primaryActionTriggered)
        let letters = symbols ? ".,?!'\\|" : (language == .korean ? "ㅋㅌㅊㅍㅠㅜㅡ" : (shifted ? "ZXCVBNM" : "zxcvbnm"))
        row([shift] + characters(letters) + [delete])
        row([
            button("한/영") { [weak self] in self?.onKey?(.language) },
            button(symbols ? "ABC" : "#+=") { [weak self] in self?.symbols.toggle(); self?.rebuild() },
            button("Tab") { [weak self] in self?.onKey?(.tab) },
            button("공백") { [weak self] in self?.onKey?(.text(" ")) },
            button("Enter") { [weak self] in self?.onKey?(.enter) },
            button("닫기") { [weak self] in self?.onKey?(.hide) }
        ])
    }
    @objc private func startDelete() {
        stopDelete(); deleteRepeated = false
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.deleteRepeated = true
            self?.onKey?(.delete)
            self?.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.075, repeats: true) { [weak self] _ in self?.onKey?(.delete) }
        }
    }
    @objc private func stopDelete() { deleteTimer?.invalidate(); deleteTimer = nil }
    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { stopDelete() }
        super.willMove(toWindow: newWindow)
    }
}

/// Recompose a short word from its jamo history so Backspace removes one keystroke,
/// including compound vowels/finals. A caret/focus change commits the history.
struct HangulComposer {
    private var keys: [Character] = []
    private(set) var text = ""
    mutating func append(_ jamo: Character) { keys.append(jamo); text = Self.compose(keys) }
    mutating func delete() { if !keys.isEmpty { keys.removeLast() }; text = Self.compose(keys) }
    mutating func reset() { keys.removeAll(); text = "" }
    var isEmpty: Bool { keys.isEmpty }
    static func isJamo(_ ch: Character) -> Bool { initials.contains(ch) || vowels.contains(ch) }
    private static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let vowels = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    private static let finals = Array(" ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    private static let vowelPairs = ["ㅗㅏ":"ㅘ", "ㅗㅐ":"ㅙ", "ㅗㅣ":"ㅚ", "ㅜㅓ":"ㅝ", "ㅜㅔ":"ㅞ", "ㅜㅣ":"ㅟ", "ㅡㅣ":"ㅢ"]
    private static let finalPairs = ["ㄱㅅ":"ㄳ", "ㄴㅈ":"ㄵ", "ㄴㅎ":"ㄶ", "ㄹㄱ":"ㄺ", "ㄹㅁ":"ㄻ", "ㄹㅂ":"ㄼ", "ㄹㅅ":"ㄽ", "ㄹㅌ":"ㄾ", "ㄹㅍ":"ㄿ", "ㄹㅎ":"ㅀ", "ㅂㅅ":"ㅄ"]

    private static func compose(_ keys: [Character]) -> String {
        var output = "", lead: Int?, vowel: Int?, tail = 0
        func current() -> String {
            if let l = lead, let v = vowel { return String(UnicodeScalar(0xAC00 + (l * 21 + v) * 28 + tail)!) }
            if let l = lead { return String(initials[l]) }
            if let v = vowel { return String(vowels[v]) }
            return ""
        }
        func flush() { output += current(); lead = nil; vowel = nil; tail = 0 }
        for ch in keys {
            if let nextVowel = vowels.firstIndex(of: ch) {
                if vowel == nil { vowel = nextVowel }
                else if tail != 0 {
                    let trailing = finals[tail]
                    let pair = finalPairs.first(where: { $0.value == String(trailing) }).map { Array($0.key) }
                    tail = pair.flatMap { finals.firstIndex(of: $0[0]) } ?? 0
                    output += current()
                    lead = initials.firstIndex(of: pair?.last ?? trailing)
                    vowel = nextVowel; tail = 0
                } else if let combined = vowelPairs[String(vowels[vowel!]) + String(ch)], let index = vowels.firstIndex(of: Character(combined)) {
                    vowel = index
                } else { flush(); vowel = nextVowel }
            } else if let nextLead = initials.firstIndex(of: ch) {
                if lead != nil && vowel != nil, let nextTail = finals.firstIndex(of: ch) {
                    if tail == 0 { tail = nextTail }
                    else if let combined = finalPairs[String(finals[tail]) + String(ch)], let index = finals.firstIndex(of: Character(combined)) { tail = index }
                    else { flush(); lead = nextLead }
                } else { flush(); lead = nextLead }
            } else { flush(); output += String(ch) }
        }
        return output + current()
    }
}
