import UIKit

final class CalculatorContent: AppContentView, KeyInputTarget {
    private let expressionLabel = UILabel()
    private let displayLabel = UILabel()
    private var buttons: [(String, DeskButton)] = []
    private static let keys: [[String]] = [
        ["C", "±", "%", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["0", ".", "⌫", "="],
    ]

    private var current = "0"
    private var accumulator: Double?
    private var pendingOperator: String?
    private var startNewNumber = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: 0x17181B)
        expressionLabel.textColor = Theme.secondaryText
        expressionLabel.textAlignment = .right
        displayLabel.textColor = Theme.text
        displayLabel.textAlignment = .right
        displayLabel.adjustsFontSizeToFitWidth = true
        displayLabel.minimumScaleFactor = 0.4
        addSubview(expressionLabel)
        addSubview(displayLabel)
        for row in CalculatorContent.keys {
            for key in row {
                let button = DeskButton(title: key)
                button.fontSize = 20
                button.cornerRadius = 10
                let isOperator = "÷×−+=".contains(key)
                let isFunction = "C±%⌫".contains(key)
                button.normalBackground = isOperator ? Theme.accent : (isFunction ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 1, alpha: 0.07))
                button.hoverBackground = isOperator ? Theme.accent.withAlphaComponent(0.8) : UIColor(white: 1, alpha: 0.2)
                button.tint = isOperator ? .white : Theme.text
                button.onTap = { [weak self] in self?.press(key) }
                buttons.append((key, button))
                addSubview(button)
            }
        }
        title = "계산기"
        updateDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? { self }

    override func layoutSubviews() {
        super.layoutSubviews()
        let padding = Theme.s(12)
        let gap = Theme.s(8)
        let displayHeight = max(Theme.s(90), bounds.height * 0.26)
        expressionLabel.font = Theme.font(15)
        displayLabel.font = Theme.font(44, .light)
        expressionLabel.frame = CGRect(x: padding, y: padding, width: bounds.width - padding * 2, height: Theme.s(22))
        displayLabel.frame = CGRect(x: padding, y: expressionLabel.frame.maxY, width: bounds.width - padding * 2, height: displayHeight - expressionLabel.frame.maxY)
        let rows = CGFloat(CalculatorContent.keys.count)
        let cellWidth = (bounds.width - padding * 2 - gap * 3) / 4
        let cellHeight = (bounds.height - displayHeight - padding - gap * (rows - 1)) / rows
        for (index, entry) in buttons.enumerated() {
            let row = CGFloat(index / 4)
            let column = CGFloat(index % 4)
            entry.1.frame = CGRect(x: padding + column * (cellWidth + gap), y: displayHeight + row * (cellHeight + gap), width: cellWidth, height: max(0, cellHeight))
        }
    }

    // MARK: Logic

    private func value(_ string: String) -> Double {
        Double(string) ?? 0
    }

    private func format(_ number: Double) -> String {
        guard number.isFinite else { return "오류" }
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int64(number))
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        formatter.minimumIntegerDigits = 1
        if abs(number) >= 1e15 || abs(number) < 1e-9 {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 8
        } else {
            formatter.numberStyle = .decimal
        }
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func compute(_ lhs: Double, _ op: String, _ rhs: Double) -> Double {
        switch op {
        case "+": return lhs + rhs
        case "−": return lhs - rhs
        case "×": return lhs * rhs
        case "÷": return rhs == 0 ? .nan : lhs / rhs
        default: return rhs
        }
    }

    private func applyPending() {
        let operand = value(current)
        if let op = pendingOperator, let lhs = accumulator {
            if !startNewNumber {
                let result = compute(lhs, op, operand)
                current = format(result)
                accumulator = result.isFinite ? result : nil
            }
        } else {
            accumulator = operand
        }
    }

    func press(_ key: String) {
        if current == "오류" && key != "C" {
            current = "0"
            accumulator = nil
            pendingOperator = nil
            startNewNumber = true
        }
        switch key {
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if startNewNumber || current == "0" {
                current = key
                startNewNumber = false
            } else if current.count < 16 {
                current += key
            }
        case ".":
            if startNewNumber {
                current = "0."
                startNewNumber = false
            } else if !current.contains(".") {
                current += "."
            }
        case "C":
            current = "0"
            accumulator = nil
            pendingOperator = nil
            startNewNumber = true
        case "±":
            if current != "0" { current = current.hasPrefix("-") ? String(current.dropFirst()) : "-" + current }
        case "%":
            current = format(value(current) / 100)
            startNewNumber = true
        case "⌫":
            if !startNewNumber {
                current.removeLast()
                if current.isEmpty || current == "-" {
                    current = "0"
                    startNewNumber = true
                }
            }
        case "+", "−", "×", "÷":
            applyPending()
            pendingOperator = key
            startNewNumber = true
        case "=":
            applyPending()
            pendingOperator = nil
            accumulator = nil
            startNewNumber = true
        default:
            break
        }
        updateDisplay()
    }

    private func updateDisplay() {
        displayLabel.text = current
        if let op = pendingOperator, let lhs = accumulator {
            expressionLabel.text = "\(format(lhs)) \(op)"
        } else {
            expressionLabel.text = ""
        }
        for (key, button) in buttons where key == "C" {
            button.title = (startNewNumber && accumulator == nil) ? "AC" : "C"
        }
    }

    // MARK: Keyboard

    var acceptsTextInput: Bool { false }
    var inputDescription: String { "계산기" }

    func insertText(_ text: String) {
        for character in text {
            switch character {
            case "0"..."9": press(String(character))
            case ".", ",": press(".")
            case "+": press("+")
            case "-": press("−")
            case "*", "x", "X": press("×")
            case "/": press("÷")
            case "%": press("%")
            case "=": press("=")
            case "c", "C": press("C")
            default: break
            }
        }
    }

    func deleteBackward() {
        press("⌫")
    }

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        switch key {
        case .enter: press("=")
        case .escape: press("C")
        case .deleteForward: press("C")
        default: break
        }
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "c":
            UIPasteboard.general.string = current
            desktop?.showToast("결과를 복사했습니다: \(current)", symbol: "doc.on.doc")
            return true
        case "v":
            if let text = UIPasteboard.general.string {
                let digits = text.filter { "0123456789.-".contains($0) }
                if Double(digits) != nil {
                    current = digits
                    startNewNumber = false
                    updateDisplay()
                }
            }
            return true
        default:
            return false
        }
    }
}

/// Built-in guide: gestures, shortcuts and limitations.
final class HelpContent: AppContentView {
    private let textView = UITextView()
    private var renderedScale: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.windowBackground
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.indicatorStyle = .white
        textView.contentInsetAdjustmentBehavior = .never
        addSubview(textView)
        title = "PocketDesk 도움말"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        textView.textContainerInset = UIEdgeInsets(top: Theme.s(22), left: Theme.s(26), bottom: Theme.s(26), right: Theme.s(26))
        if renderedScale != Theme.scale {
            renderedScale = Theme.scale
            textView.attributedText = HelpContent.makeText()
        }
    }

    private static let sections: [(String, [String])] = [
        ("PocketDesk에 오신 것을 환영합니다", [
            "아이폰을 모니터나 TV에 연결하면 이 데스크톱이 나타나고, 아이폰 화면은 트랙패드와 키보드가 됩니다.",
            "USB-C → HDMI 케이블(또는 허브)로 연결하거나, 제어 센터 › 화면 미러링으로 Apple TV·AirPlay TV에 무선으로 연결할 수 있습니다.",
        ]),
        ("아이폰 트랙패드", [
            "한 손가락으로 움직이기: 포인터 이동",
            "탭: 클릭  ·  두 번 탭: 더블클릭",
            "두 손가락 탭: 오른쪽 클릭 (메뉴)",
            "두 손가락으로 쓸기: 스크롤",
            "두 번 탭한 뒤 손을 떼지 않고 움직이기 (또는 길게 누른 뒤 움직이기): 드래그 — 창 이동, 텍스트 선택",
            "세 손가락 탭: 가운데 클릭 (링크를 새 탭에서 열기)",
            "아래쪽 [왼쪽]/[오른쪽] 버튼을 누른 채 다른 손가락으로 움직여도 드래그할 수 있습니다.",
        ]),
        ("키보드", [
            "블루투스 키보드를 연결하면 바로 입력할 수 있습니다. 한/영 전환은 Ctrl+Space 또는 지구본 키를 사용하세요 (설정 › 일반 › 키보드 › 하드웨어 키보드에서 Caps Lock 전환도 가능).",
            "키보드가 없으면 아이폰 화면의 [키보드] 버튼으로 화상 키보드를 띄우세요. 입력란을 클릭하면 자동으로 나타납니다.",
        ]),
        ("단축키 (⌘ 또는 Ctrl)", [
            "⌘T 새 탭  ·  ⌘N 새 창  ·  ⌘W 탭/창 닫기  ·  ⌘M 최소화",
            "⌘L 주소창  ·  ⌘R 새로 고침  ·  ⌘[ / ⌘] 뒤로/앞으로  ·  ⌘+ / ⌘− 확대/축소",
            "⌘C 복사  ·  ⌘X 잘라내기  ·  ⌘V 붙여넣기  ·  ⌘A 모두 선택  ·  ⌘Z 실행 취소",
            "⌥Tab 또는 ⌘Tab: 창 전환  ·  Ctrl+Tab: 브라우저 탭 전환",
            "⌘Esc 또는 Ctrl+Esc: 시작 메뉴  ·  Esc: 메뉴 닫기, 전체 화면 끝내기",
        ]),
        ("창 다루기", [
            "제목 표시줄을 끌어 옮기고, 가장자리를 끌어 크기를 바꿉니다.",
            "창을 화면 왼쪽/오른쪽 끝으로 끌면 화면 절반에, 위쪽 끝으로 끌면 최대화됩니다.",
            "제목 표시줄을 더블클릭하면 최대화/복원됩니다. 오른쪽 클릭하면 창 메뉴가 열립니다.",
        ]),
        ("진짜 데스크톱 앱이 필요하면 — 원격 데스크톱", [
            "iOS 정책상 다른 아이폰 앱을 이 창에 띄울 수는 없지만, '원격 데스크톱' 앱으로 내 PC·Mac·미니PC·클라우드 PC 화면을 모니터에 띄우면 그 안의 모든 프로그램(카카오톡 PC, 오피스, 포토샵 등)을 트랙패드와 키보드로 그대로 쓸 수 있습니다.",
            "호스트 준비: Windows는 TightVNC·UltraVNC·RealVNC 서버 설치 / Mac은 시스템 설정 › 일반 › 공유 › 화면 공유를 켜고 VNC 비밀번호 설정 / Linux는 x11vnc·TigerVNC.",
            "같은 Wi-Fi면 주소(예: 192.168.0.10)와 VNC 비밀번호만 넣으면 됩니다. ⌘ 단축키는 원격의 Ctrl로 전달됩니다(복사=⌘C→Ctrl+C).",
        ]),
        ("알아 두세요", [
            "이 데스크톱 안의 앱(인터넷·파일·메모 등)은 iOS 앱 하나로 직접 만든 것입니다. 웹 서비스는 브라우저(YouTube, Gmail, Google 문서, 네이버 등), 설치형 프로그램은 원격 데스크톱으로 사용하세요.",
            "PocketDesk가 화면에 떠 있는 동안에만 데스크톱이 유지됩니다. 홈 화면으로 나가면 모니터는 일반 미러링으로 돌아가고, 다시 앱을 열면 창들이 그대로 복원됩니다.",
            "아이폰 화면이 꺼지면 연결도 멈춥니다. 연결 중에는 자동 잠금이 꺼지며, [어둡게] 버튼으로 배터리를 아낄 수 있습니다.",
            "웹페이지 안의 드래그 앤 드롭, 파일 업로드 버튼 등 일부 기능은 동작하지 않을 수 있습니다.",
        ]),
    ]

    private static func makeText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = Theme.s(8)
        titleStyle.paragraphSpacingBefore = Theme.s(14)
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = Theme.s(3)
        bodyStyle.paragraphSpacing = Theme.s(6)
        bodyStyle.headIndent = Theme.s(16)
        bodyStyle.firstLineHeadIndent = 0
        for (index, section) in sections.enumerated() {
            result.append(NSAttributedString(string: section.0 + "\n", attributes: [
                .font: Theme.font(index == 0 ? 22 : 16, .bold),
                .foregroundColor: index == 0 ? Theme.text : Theme.accent,
                .paragraphStyle: titleStyle,
            ]))
            for line in section.1 {
                result.append(NSAttributedString(string: "•  " + line + "\n", attributes: [
                    .font: Theme.font(13.5),
                    .foregroundColor: Theme.text,
                    .paragraphStyle: bodyStyle,
                ]))
            }
        }
        return result
    }
}
