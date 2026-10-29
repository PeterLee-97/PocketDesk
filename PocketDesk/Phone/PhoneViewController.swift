import UIKit

/// The phone screen: a welcome/instructions page until a display is connected, then a
/// trackpad + keyboard controller for the desktop on the external display.
final class PhoneViewController: UIViewController {
    private let welcome = WelcomeView()
    private let controller = UIView()
    private let statusDot = UIView()
    private let statusLabel = UILabel()
    private let focusLabel = UILabel()
    private let buttonRow = UIStackView()
    private let trackpad = TrackpadView()
    private let hintLabel = UILabel()
    private let clickRow = UIStackView()
    private let keySink = KeyboardSinkView()
    private lazy var accessoryBar = KeyboardAccessoryBar(sink: keySink)
    private var keyboardButton: UIButton?

    private let dimOverlay = UIView()
    private let dimTrackpad = TrackpadView()
    private let dimExitButton = UIButton(type: .system)

    private let sceneAccessory = ExternalDisplayAccessory()
    private var keyboardRequested = false
    private var keyboardAutoShown = false
    private var isDimmed = false
    private var savedBrightness: CGFloat = 0.6

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        DeskSession.shared.phone = self
        UIApplication.shared.applicationSupportsShakeToEdit = false

        view.addSubview(keySink)
        accessoryBar.onHide = { [weak self] in self?.setKeyboard(requested: false) }

        welcome.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(welcome)
        controller.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller)
        NSLayoutConstraint.activate([
            welcome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            welcome.topAnchor.constraint(equalTo: view.topAnchor),
            welcome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.topAnchor.constraint(equalTo: view.topAnchor),
            controller.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        buildController()
        buildDimOverlay()

        NotificationCenter.default.addObserver(self, selector: #selector(hardwareChanged), name: HardwareInput.didChange, object: nil)
        displayStateDidChange()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sceneAccessory.register(from: self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { DeskSession.shared.isDisplayConnected }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        DeskSession.shared.isDisplayConnected ? [.bottom, .top] : []
    }
    override var prefersStatusBarHidden: Bool { isDimmed }

    // MARK: Building the controller UI

    private func makeToolButton(_ title: String, symbol: String, action: UIAction? = nil, menu: UIMenu? = nil) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.title = title
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.baseBackgroundColor = UIColor(white: 1, alpha: 0.1)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
            return outgoing
        }
        let button = UIButton(configuration: configuration, primaryAction: action)
        if let menu {
            button.menu = menu
            button.showsMenuAsPrimaryAction = true
        }
        return button
    }

    private func buildController() {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        controller.addSubview(header)
        statusDot.backgroundColor = UIColor(hex: 0x34C759)
        statusDot.layer.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        focusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        focusLabel.textColor = UIColor(white: 1, alpha: 0.55)
        focusLabel.textAlignment = .right
        focusLabel.translatesAutoresizingMaskIntoConstraints = false
        focusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for subview in [statusDot, statusLabel, focusLabel] { header.addSubview(subview) }

        let start = makeToolButton("시작", symbol: "square.grid.2x2.fill", action: UIAction { _ in
            DeskSession.shared.desktop?.toggleStartMenu()
        })
        let windows = makeToolButton("창", symbol: "macwindow.on.rectangle", menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.windowMenuItems() ?? []) },
        ]))
        let escape = makeToolButton("Esc", symbol: "escape", action: UIAction { _ in
            DeskSession.shared.specialKey(.escape, modifiers: [])
        })
        let keyboard = makeToolButton("키보드", symbol: "keyboard", action: UIAction { [weak self] _ in
            guard let self else { return }
            self.setKeyboard(requested: !self.keySink.isFirstResponder)
        })
        keyboardButton = keyboard
        let dim = makeToolButton("어둡게", symbol: "moon.fill", action: UIAction { [weak self] _ in
            self?.setDimmed(true)
        })
        let more = makeToolButton("더보기", symbol: "ellipsis.circle", menu: UIMenu(children: [
            UIAction(title: "포인터를 화면 가운데로", image: UIImage(systemName: "scope")) { _ in
                DeskSession.shared.desktop?.centerPointer()
            },
            UIAction(title: "데스크톱 설정", image: UIImage(systemName: "gearshape")) { _ in
                DeskSession.shared.desktop?.open(.settings)
            },
            UIAction(title: "도움말", image: UIImage(systemName: "questionmark.circle")) { _ in
                DeskSession.shared.desktop?.open(.help)
            },
        ]))
        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        for button in [start, windows, escape, keyboard, dim, more] { buttonRow.addArrangedSubview(button) }
        controller.addSubview(buttonRow)

        trackpad.backgroundColor = UIColor(white: 1, alpha: 0.06)
        trackpad.layer.cornerRadius = 22
        trackpad.layer.borderWidth = 1
        trackpad.layer.borderColor = UIColor(white: 1, alpha: 0.1).cgColor
        trackpad.translatesAutoresizingMaskIntoConstraints = false
        trackpad.onFirstUse = { [weak self] in self?.fadeHint() }
        controller.addSubview(trackpad)
        hintLabel.text = "한 손가락: 포인터 이동 · 탭: 클릭\n두 손가락: 스크롤 · 두 손가락 탭: 오른쪽 클릭\n두 번 탭한 채로 움직이기: 드래그"
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.font = .systemFont(ofSize: 13)
        hintLabel.textColor = UIColor(white: 1, alpha: 0.35)
        hintLabel.isUserInteractionEnabled = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        trackpad.addSubview(hintLabel)

        clickRow.axis = .horizontal
        clickRow.distribution = .fillEqually
        clickRow.spacing = 8
        clickRow.translatesAutoresizingMaskIntoConstraints = false
        clickRow.addArrangedSubview(TrackpadButton(title: "왼쪽 클릭", button: .left))
        clickRow.addArrangedSubview(TrackpadButton(title: "오른쪽 클릭", button: .right))
        controller.addSubview(clickRow)

        let guide = controller.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: 24),
            statusDot.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            focusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            focusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            focusLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            buttonRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            buttonRow.heightAnchor.constraint(equalToConstant: 54),

            trackpad.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 10),
            trackpad.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            trackpad.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            trackpad.bottomAnchor.constraint(equalTo: clickRow.topAnchor, constant: -8),

            hintLabel.centerXAnchor.constraint(equalTo: trackpad.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: trackpad.centerYAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: trackpad.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trackpad.trailingAnchor, constant: -16),

            clickRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            clickRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            clickRow.heightAnchor.constraint(equalToConstant: 58),
            clickRow.bottomAnchor.constraint(equalTo: controller.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
    }

    private func buildDimOverlay() {
        dimOverlay.backgroundColor = .black
        dimOverlay.isHidden = true
        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimOverlay)
        dimTrackpad.backgroundColor = .black
        dimTrackpad.translatesAutoresizingMaskIntoConstraints = false
        dimOverlay.addSubview(dimTrackpad)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "화면 밝게"
        configuration.image = UIImage(systemName: "sun.max")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = UIColor(white: 1, alpha: 0.35)
        dimExitButton.configuration = configuration
        dimExitButton.addAction(UIAction { [weak self] _ in self?.setDimmed(false) }, for: .primaryActionTriggered)
        dimExitButton.translatesAutoresizingMaskIntoConstraints = false
        dimOverlay.addSubview(dimExitButton)
        NSLayoutConstraint.activate([
            dimOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dimExitButton.topAnchor.constraint(equalTo: dimOverlay.safeAreaLayoutGuide.topAnchor, constant: 4),
            dimExitButton.centerXAnchor.constraint(equalTo: dimOverlay.centerXAnchor),
            dimTrackpad.topAnchor.constraint(equalTo: dimExitButton.bottomAnchor, constant: 4),
            dimTrackpad.leadingAnchor.constraint(equalTo: dimOverlay.leadingAnchor),
            dimTrackpad.trailingAnchor.constraint(equalTo: dimOverlay.trailingAnchor),
            dimTrackpad.bottomAnchor.constraint(equalTo: dimOverlay.bottomAnchor),
        ])
    }

    private func fadeHint() {
        guard hintLabel.alpha > 0 else { return }
        UIView.animate(withDuration: 0.6, delay: 2.5, options: []) { self.hintLabel.alpha = 0 }
    }

    private func windowMenuItems() -> [UIMenuElement] {
        guard let desktop = DeskSession.shared.desktop else { return [] }
        var items: [UIMenuElement] = desktop.focusOrder.map { window in
            UIAction(title: window.displayTitle, subtitle: window.kind.title,
                     image: UIImage(systemName: window.isMinimized ? "minus.square" : "macwindow"),
                     state: window === desktop.activeWindow ? .on : .off) { [weak window] _ in
                if let window { DeskSession.shared.desktop?.focus(window) }
            }
        }
        if items.isEmpty {
            items.append(UIAction(title: "열린 창이 없습니다", attributes: .disabled) { _ in })
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "새 브라우저 창", image: UIImage(systemName: "globe")) { _ in DeskSession.shared.desktop?.open(.browser) },
            UIAction(title: "내 파일", image: UIImage(systemName: "folder")) { _ in DeskSession.shared.desktop?.open(.files) },
            UIAction(title: "모든 창 최소화", image: UIImage(systemName: "menubar.dock.rectangle")) { _ in DeskSession.shared.desktop?.minimizeAll() },
            UIAction(title: "모든 창 닫기", image: UIImage(systemName: "xmark.square"), attributes: .destructive) { _ in DeskSession.shared.desktop?.closeAllWindows() },
        ]))
        return items
    }

    // MARK: State

    func displayStateDidChange() {
        let connected = DeskSession.shared.isDisplayConnected
        welcome.isHidden = connected
        controller.isHidden = !connected
        statusLabel.text = "모니터 연결됨 · \(DeskSession.shared.displayDescription)"
        welcome.update(openWindows: DeskSession.shared.desktop?.windows.count ?? 0)
        UIApplication.shared.isIdleTimerDisabled = connected
        if !connected {
            setDimmed(false)
            keyboardRequested = false
            keyboardAutoShown = false
        }
        updateKeyboard()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        keyFocusDidChange()
    }

    func phoneDidBecomeActive() {
        if isDimmed, let screen = view.window?.windowScene?.screen { screen.brightness = 0.02 }
        updateKeyboard()
    }

    func phoneWillResignActive() {
        if isDimmed, let screen = view.window?.windowScene?.screen { screen.brightness = savedBrightness }
    }

    @objc private func hardwareChanged() {
        updateKeyboard()
    }

    func keyFocusDidChange() {
        let target = DeskSession.shared.keyFocus
        if let target, !target.inputDescription.isEmpty {
            focusLabel.text = "⌨︎ " + target.inputDescription
        } else {
            focusLabel.text = ""
        }
        let type = target?.keyboardType ?? .default
        if keySink.keyboardType != type {
            keySink.keyboardType = type
            if keySink.isFirstResponder { keySink.reloadInputViews() }
        }
        if Settings.shared.autoShowKeyboard && !HardwareInput.shared.hasKeyboard && !keyboardRequested {
            keyboardAutoShown = target?.acceptsTextInput ?? false
        }
        updateKeyboard()
    }

    private func setKeyboard(requested: Bool) {
        keyboardRequested = requested
        if !requested { keyboardAutoShown = false }
        updateKeyboard()
    }

    private func updateKeyboard() {
        let connected = DeskSession.shared.isDisplayConnected
        let hardware = HardwareInput.shared.hasKeyboard
        let accessory: UIView? = hardware ? nil : accessoryBar
        if keySink.inputAccessoryView !== accessory {
            keySink.inputAccessoryView = accessory
            if keySink.isFirstResponder { keySink.reloadInputViews() }
        }
        let wantsFocus = connected && !isDimmed && (hardware || keyboardRequested || keyboardAutoShown)
        if wantsFocus && !keySink.isFirstResponder {
            keySink.clearBuffer()
            keySink.becomeFirstResponder()
        } else if !wantsFocus && keySink.isFirstResponder {
            keySink.resignFirstResponder()
        }
        var configuration = keyboardButton?.configuration
        configuration?.baseBackgroundColor = (keySink.isFirstResponder && !hardware) ? UIColor(hex: 0x4A8FFF) : UIColor(white: 1, alpha: 0.1)
        keyboardButton?.configuration = configuration
    }

    private func setDimmed(_ dimmed: Bool) {
        guard dimmed != isDimmed else { return }
        isDimmed = dimmed
        let screen = view.window?.windowScene?.screen
        if dimmed {
            savedBrightness = screen?.brightness ?? savedBrightness
            screen?.brightness = 0.02
        } else {
            screen?.brightness = savedBrightness
        }
        dimOverlay.isHidden = !dimmed
        view.bringSubviewToFront(dimOverlay)
        setNeedsStatusBarAppearanceUpdate()
        updateKeyboard()
    }

    func presentFromDesktop(_ viewController: UIViewController) {
        if isDimmed { setDimmed(false) }
        if let presented = presentedViewController {
            presented.dismiss(animated: false) { [weak self] in self?.present(viewController, animated: true) }
        } else {
            present(viewController, animated: true)
        }
    }
}

/// Shown while no external display is connected.
private final class WelcomeView: UIView {
    private let stack = UIStackView()
    private let windowsLabel = UILabel()
    private let waitingLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let icon = UIImageView(image: UIImage(systemName: "iphone.and.arrow.forward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 46, weight: .light)))
        icon.tintColor = UIColor(hex: 0x4A8FFF)
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = "PocketDesk"
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textColor = .white
        let subtitle = UILabel()
        subtitle.text = "아이폰을 컴퓨터처럼 — 모니터에 연결하면 데스크톱이 열립니다"
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = UIColor(white: 1, alpha: 0.65)
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        let steps = UIStackView()
        steps.axis = .vertical
        steps.spacing = 14
        steps.isLayoutMarginsRelativeArrangement = true
        steps.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        steps.backgroundColor = UIColor(white: 1, alpha: 0.07)
        steps.layer.cornerRadius = 18
        let items: [(String, String)] = [
            ("cable.connector", "USB-C → HDMI 케이블이나 허브로 모니터·TV에 연결하세요. (USB-C 모니터는 케이블 하나로 충분합니다)"),
            ("airplayvideo", "또는 제어 센터 › 화면 미러링으로 Apple TV·AirPlay TV에 무선 연결하세요."),
            ("keyboard", "블루투스 키보드를 연결하면 더 편합니다. (설정 › Bluetooth)"),
            ("hand.point.up.left", "연결되면 이 화면이 트랙패드가 됩니다."),
        ]
        for (symbol, text) in items {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 12
            row.alignment = .top
            let image = UIImageView(image: UIImage(systemName: symbol))
            image.tintColor = UIColor(hex: 0x4A8FFF)
            image.contentMode = .scaleAspectFit
            image.widthAnchor.constraint(equalToConstant: 26).isActive = true
            image.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 14)
            label.textColor = UIColor(white: 1, alpha: 0.85)
            label.numberOfLines = 0
            row.addArrangedSubview(image)
            row.addArrangedSubview(label)
            steps.addArrangedSubview(row)
        }

        waitingLabel.text = "● 모니터를 기다리는 중…"
        waitingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        waitingLabel.textColor = UIColor(white: 1, alpha: 0.5)
        windowsLabel.font = .systemFont(ofSize: 13)
        windowsLabel.textColor = UIColor(hex: 0x34C759)
        windowsLabel.numberOfLines = 0
        windowsLabel.textAlignment = .center

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [icon, title, subtitle, steps, waitingLabel, windowsLabel] as [UIView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(26, after: subtitle)
        steps.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 60),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
        ])
        startPulse()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func startPulse() {
        UIView.animate(withDuration: 1.1, delay: 0, options: [.autoreverse, .repeat, .allowUserInteraction]) {
            self.waitingLabel.alpha = 0.25
        }
    }

    func update(openWindows: Int) {
        windowsLabel.text = openWindows > 0 ? "열려 있던 창 \(openWindows)개는 다시 연결하면 그대로 복원됩니다." : nil
        windowsLabel.isHidden = openWindows == 0
    }
}
