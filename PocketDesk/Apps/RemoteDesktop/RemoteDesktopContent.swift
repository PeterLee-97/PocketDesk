import UIKit
import Security

/// X11 keysym mapping for sending our virtual keyboard to a VNC host.
enum Keysym {
    static let shiftL: UInt32 = 0xFFE1
    static let controlL: UInt32 = 0xFFE3
    static let altL: UInt32 = 0xFFE9
    static let superL: UInt32 = 0xFFEB

    static func special(_ key: SpecialKey) -> UInt32 {
        switch key {
        case .enter: return 0xFF0D
        case .tab: return 0xFF09
        case .escape: return 0xFF1B
        case .backspace: return 0xFF08
        case .deleteForward: return 0xFFFF
        case .left: return 0xFF51
        case .up: return 0xFF52
        case .right: return 0xFF53
        case .down: return 0xFF54
        case .home: return 0xFF50
        case .end: return 0xFF57
        case .pageUp: return 0xFF55
        case .pageDown: return 0xFF56
        }
    }

    /// A Unicode scalar as an X11 keysym. ASCII maps to itself; everything else uses the
    /// Unicode-keysym range (0x01000000 + code point), which TigerVNC/x11vnc understand.
    static func unicode(_ scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if value >= 0x20 && value <= 0x7E { return value }
        if value == 0x0A || value == 0x0D { return 0xFF0D }
        if value == 0x09 { return 0xFF09 }
        return 0x01000000 + value
    }
}

/// Shows a remote computer's screen and drives it with our virtual pointer + keyboard.
final class RemoteScreenView: UIView, PointerTarget, HoverTarget, ScrollTarget, CursorProvider, KeyInputTarget, ZoomTarget {
    weak var client: VNCClient?
    private let imageLayer = CALayer()
    private var displayRect: CGRect = .zero
    private var frameSize: CGSize = .zero
    private var buttonMask: UInt8 = 0
    private var zoomFactor: CGFloat = 1
    private var pan = CGPoint.zero
    private var wheelRemainder = CGPoint.zero
    var inputDescription = "원격 데스크톱"
    /// Map ⌘ to the remote's Ctrl (what Windows/Linux hosts expect for copy/paste/etc.).
    var mapCommandToControl = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.contentsGravity = .resize
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setFrameImage(_ image: CGImage, size: CGSize) {
        frameSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        layoutImage()
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutImage()
    }

    private func layoutImage() {
        guard frameSize.width > 0, frameSize.height > 0, bounds.width > 0 else {
            displayRect = bounds
            imageLayer.frame = bounds
            return
        }
        let scale = min(bounds.width / frameSize.width, bounds.height / frameSize.height) * zoomFactor
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        pan.x = min(max(pan.x, -max(0, size.width - bounds.width) / 2), max(0, size.width - bounds.width) / 2)
        pan.y = min(max(pan.y, -max(0, size.height - bounds.height) / 2), max(0, size.height - bounds.height) / 2)
        displayRect = CGRect(x: (bounds.width - size.width) / 2 + pan.x, y: (bounds.height - size.height) / 2 + pan.y,
                             width: size.width, height: size.height)
        imageLayer.frame = displayRect
    }

    /// Desktop point → framebuffer pixel. Returns nil when outside the image (letterbox bars).
    private func pixel(for event: PointerEvent) -> (x: Int, y: Int)? {
        guard displayRect.width > 0, frameSize.width > 0 else { return nil }
        let point = event.location(in: self)
        guard displayRect.contains(point) else {
            // Still clamp to the edge so dragging off-image keeps controlling the cursor.
            let x = (point.x - displayRect.minX) / displayRect.width * frameSize.width
            let y = (point.y - displayRect.minY) / displayRect.height * frameSize.height
            return (Int(max(0, min(frameSize.width - 1, x))), Int(max(0, min(frameSize.height - 1, y))))
        }
        let x = (point.x - displayRect.minX) / displayRect.width * frameSize.width
        let y = (point.y - displayRect.minY) / displayRect.height * frameSize.height
        return (Int(x), Int(y))
    }

    private func bit(for button: PointerButton) -> UInt8 {
        switch button {
        case .left: return 0x01
        case .middle: return 0x02
        case .right: return 0x04
        }
    }

    // MARK: Pointer

    func pointerDown(_ event: PointerEvent) -> Bool {
        DeskSession.shared.desktop?.setKeyFocus(self)
        guard let pixel = pixel(for: event) else { return true }
        buttonMask |= bit(for: event.button)
        client?.sendPointer(x: pixel.x, y: pixel.y, buttonMask: buttonMask, force: true)
        return true
    }

    func pointerDragged(_ event: PointerEvent) {
        guard let pixel = pixel(for: event) else { return }
        client?.sendPointer(x: pixel.x, y: pixel.y, buttonMask: buttonMask)
    }

    func pointerUp(_ event: PointerEvent) {
        buttonMask &= ~bit(for: event.button)
        if let pixel = pixel(for: event) {
            client?.sendPointer(x: pixel.x, y: pixel.y, buttonMask: buttonMask, force: true)
        }
    }

    func pointerMoved(_ event: PointerEvent) {
        guard let pixel = pixel(for: event) else { return }
        client?.sendPointer(x: pixel.x, y: pixel.y, buttonMask: buttonMask)
    }

    func scroll(by delta: CGPoint, event: PointerEvent) -> Bool {
        if zoomFactor > 1.01 {
            pan.x -= delta.x; pan.y -= delta.y
            layoutImage()
            return true
        }
        if let pixel = pixel(for: event) {
            client?.sendPointer(x: pixel.x, y: pixel.y, buttonMask: buttonMask)
        }
        wheelRemainder.x += delta.x; wheelRemainder.y += delta.y
        for horizontal in [false, true] {
            let value = horizontal ? wheelRemainder.x : wheelRemainder.y
            let steps = min(8, Int(abs(value) / 16))
            if steps > 0 {
                client?.sendScroll(horizontal: horizontal, negative: value < 0, times: steps)
                let consumed = CGFloat(steps * 16) * (value < 0 ? -1 : 1)
                if horizontal { wheelRemainder.x -= consumed } else { wheelRemainder.y -= consumed }
            }
        }
        return true
    }

    func zoom(by factor: CGFloat, event: PointerEvent) {
        guard factor.isFinite, factor > 0, displayRect.width > 0, displayRect.height > 0 else { return }
        let old = displayRect, anchor = event.location(in: self)
        zoomFactor = min(4, max(1, zoomFactor * factor))
        layoutImage()
        pan.x += anchor.x - displayRect.minX - (anchor.x - old.minX) / old.width * displayRect.width
        pan.y += anchor.y - displayRect.minY - (anchor.y - old.minY) / old.height * displayRect.height
        layoutImage()
    }

    func smartZoom(event: PointerEvent) { zoom(by: zoomFactor > 1.01 ? 1 / zoomFactor : 2, event: event) }

    func cursor(at point: CGPoint) -> CursorKind? { .arrow }

    // MARK: Keyboard

    func toggleMacInputLanguage() { client?.sendMacInputSourceToggle() }

    var acceptsTextInput: Bool { true }

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            client?.sendKeyPress(keysym: Keysym.unicode(scalar))
        }
    }

    func deleteBackward() {
        client?.sendKeyPress(keysym: Keysym.special(.backspace))
    }

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        sendComposed(keysym: Keysym.special(key), modifiers: modifiers)
    }

    func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard let scalar = key.unicodeScalars.first else { return false }
        sendComposed(keysym: Keysym.unicode(scalar), modifiers: modifiers)
        return true
    }

    /// Presses the modifier keysyms, taps `keysym`, then releases the modifiers.
    private func sendComposed(keysym: UInt32, modifiers: KeyModifiers) {
        guard let client else { return }
        var held: [UInt32] = []
        if modifiers.contains(.shift) { held.append(Keysym.shiftL) }
        if modifiers.contains(.control) || (mapCommandToControl && modifiers.contains(.command)) {
            held.append(Keysym.controlL)
        }
        if modifiers.contains(.option) { held.append(Keysym.altL) }
        if modifiers.contains(.command) && !mapCommandToControl { held.append(Keysym.superL) }
        for modifier in held { client.sendKey(keysym: modifier, down: true) }
        client.sendKeyPress(keysym: keysym)
        for modifier in held.reversed() { client.sendKey(keysym: modifier, down: false) }
    }
}

final class RemoteDesktopContent: AppContentView, VNCClientDelegate, KeyInputTarget {
    private enum Phase { case form, connecting, connected }

    private let screenView = RemoteScreenView()
    private let overlay = UIView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let disconnectButton = DeskButton(symbol: "xmark.circle", title: "연결 끊기")
    private let form = VNCConnectForm()

    private var client: VNCClient?
    private var phase: Phase = .form { didSet { updatePhase() } }
    private var currentServer: VNCClient.Server?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: 0x111214)
        title = "원격 데스크톱"
        addSubview(screenView)
        screenView.isHidden = true

        overlay.backgroundColor = UIColor(hex: 0x16171B)
        addSubview(overlay)
        spinner.color = .white
        overlay.addSubview(spinner)
        statusLabel.textColor = Theme.secondaryText
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        overlay.addSubview(statusLabel)
        disconnectButton.normalBackground = UIColor(white: 1, alpha: 0.1)
        disconnectButton.horizontalPadding = 16
        disconnectButton.onTap = { [weak self] in self?.disconnect() }
        overlay.addSubview(disconnectButton)

        form.onConnect = { [weak self] server in self?.connect(to: server) }
        addSubview(form)
        updatePhase()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? {
        phase == .connected ? screenView : (phase == .form ? form.firstField : self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        screenView.frame = bounds
        overlay.frame = bounds
        form.frame = bounds
        let spinnerY = bounds.midY - Theme.s(50)
        spinner.center = CGPoint(x: bounds.midX, y: spinnerY)
        statusLabel.frame = CGRect(x: Theme.s(24), y: spinnerY + Theme.s(26), width: bounds.width - Theme.s(48), height: Theme.s(60))
        let buttonWidth = disconnectButton.preferredWidth()
        disconnectButton.frame = CGRect(x: (bounds.width - buttonWidth) / 2, y: statusLabel.frame.maxY + Theme.s(10), width: buttonWidth, height: Theme.s(34))
    }

    private func updatePhase() {
        form.isHidden = phase != .form
        overlay.isHidden = phase == .connected || phase == .form
        screenView.isHidden = phase != .connected
        switch phase {
        case .form:
            title = "원격 데스크톱"
        case .connecting:
            spinner.startAnimating()
        case .connected:
            if let server = currentServer { VNCServerStore.save(server) }
            spinner.stopAnimating()
            if let server = currentServer { title = "원격 — \(server.name)" }
            if deskWindow?.isActive == true { desktop?.setKeyFocus(screenView) }
        }
    }

    private func connect(to server: VNCClient.Server) {
        client?.stop()
        currentServer = server
        let client = VNCClient(server: server)
        client.delegate = self
        self.client = client
        screenView.client = client
        screenView.mapCommandToControl = !server.macKeyboard
        statusLabel.text = "\(server.host):\(server.port)에 연결하는 중…"
        phase = .connecting
        client.start()
    }

    private func disconnect() {
        client?.stop()
        client = nil
        screenView.client = nil
        phase = .form
        form.reloadSaved()
    }

    override func willClose() {
        client?.stop()
        client = nil
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        // ⌘/Ctrl-W etc. should close the window, not leak into the remote; only intercept when
        // showing the form. When connected, the screen view forwards shortcuts to the host.
        false
    }

    // MARK: VNCClientDelegate

    func vncClient(_ client: VNCClient, didChange status: VNCClient.Status) {
        guard client === self.client else { return }
        switch status {
        case .connecting:
            statusLabel.text = "연결하는 중…"
        case .authenticating:
            statusLabel.text = "인증하는 중…"
        case .connected:
            phase = .connected
        case .failed(let message):
            statusLabel.text = "연결 실패\n\n\(message)"
            phase = .connecting
            spinner.stopAnimating()
            desktop?.showToast("원격 데스크톱 연결 실패", symbol: "exclamationmark.triangle")
        case .closed:
            if phase == .connected {
                desktop?.showToast("원격 데스크톱 연결이 끊어졌습니다", symbol: "bolt.horizontal.circle")
            }
            statusLabel.text = "연결이 종료되었습니다."
            phase = .connecting
            spinner.stopAnimating()
        }
    }

    func vncClient(_ client: VNCClient, didResize size: CGSize) {
        // Nothing extra: RemoteScreenView re-letterboxes on the next frame.
    }

    func vncClient(_ client: VNCClient, didRenderFrame image: CGImage) {
        guard client === self.client else { return }
        screenView.setFrameImage(image, size: client.framebufferSize)
        if phase != .connected { phase = .connected }
    }

    func vncClient(_ client: VNCClient, didReceiveClipboard text: String) {
        UIPasteboard.general.string = text
    }

    // KeyInputTarget stub for the brief window before a field is focused.
    var acceptsTextInput: Bool { false }
    var inputDescription: String { "원격 데스크톱" }
    func insertText(_ text: String) {}
    func deleteBackward() {}
    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {}
}

/// Addresses live in preferences; credentials are stored in this device's Keychain.
enum VNCServerStore {
    private static let service = "com.johnjar.pocketdesk.vnc"
    private static func account(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }
    private static func query(_ host: String, _ port: Int) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account(host, port)]
    }
    private static func password(_ host: String, _ port: Int) -> String? {
        var q = query(host, port)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult
    private static func storePassword(_ value: String, host: String, port: Int) -> Bool {
        let q = query(host, port)
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if result == errSecSuccess { return true }
        if result != errSecItemNotFound { return false }
        return SecItemAdd(q.merging(attrs) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    private static func metadata(_ server: VNCClient.Server) -> [String: Any] {
        ["name": server.name, "host": server.host, "port": server.port, "macKeyboard": server.macKeyboard]
    }
    static func all() -> [VNCClient.Server] {
        importSetupProfile()
        var raw = UserDefaults.standard.array(forKey: "vncServers") as? [[String: Any]] ?? []
        var changed = false
        let servers: [VNCClient.Server] = raw.indices.compactMap { index in
            let entry = raw[index]
            guard let host = entry["host"] as? String else { return nil }
            let port = entry["port"] as? Int ?? 5900
            let old = entry["password"] as? String
            if let old, storePassword(old, host: host, port: port) {
                raw[index].removeValue(forKey: "password"); changed = true
            }
            return VNCClient.Server(name: entry["name"] as? String ?? host, host: host, port: port,
                password: password(host, port) ?? old ?? "", macKeyboard: entry["macKeyboard"] as? Bool ?? false)
        }
        if changed { UserDefaults.standard.set(raw, forKey: "vncServers") }
        return servers
    }
    static func save(_ server: VNCClient.Server) {
        guard storePassword(server.password, host: server.host, port: server.port) else { return }
        var servers = all().filter { !($0.host == server.host && $0.port == server.port) }
        servers.insert(server, at: 0)
        UserDefaults.standard.set(servers.prefix(8).map(metadata), forKey: "vncServers")
    }
    static func remove(host: String, port: Int) {
        let servers = all().filter { !($0.host == host && $0.port == port) }
        SecItemDelete(query(host, port) as CFDictionary)
        UserDefaults.standard.set(servers.map(metadata), forKey: "vncServers")
    }
    /// Local device provisioning contains only an address, never a password or automatic connection.
    private static func importSetupProfile() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pocketdesk-remote-setup.json")
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = entry["host"] as? String, !host.isEmpty,
              let port = entry["port"] as? Int, (1...65535).contains(port) else { return }
        let server = VNCClient.Server(name: entry["name"] as? String ?? host, host: host, port: port,
            password: "", macKeyboard: entry["macKeyboard"] as? Bool ?? false)
        var entries = UserDefaults.standard.array(forKey: "vncServers") as? [[String: Any]] ?? []
        if !entries.contains(where: { $0["host"] as? String == host && $0["port"] as? Int == port }) {
            entries.insert(metadata(server), at: 0)
            UserDefaults.standard.set(entries, forKey: "vncServers")
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The connection form shown before connecting.
final class VNCConnectForm: UIView {
    var onConnect: ((VNCClient.Server) -> Void)?
    var firstField: DeskTextField { hostField }

    private let scrollView = UIScrollView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let nameField = DeskTextField(placeholder: "이름 (예: 집 PC)")
    private let hostField = DeskTextField(placeholder: "주소 (예: 192.168.0.10)")
    private let portField = DeskTextField(placeholder: "5900")
    private let passwordField = DeskTextField(placeholder: "VNC 비밀번호")
    private let connectButton = DeskButton(symbol: "bolt.fill", title: "연결")
    private let macKeyboardButton = DeskButton(symbol: "command", title: "Mac 키보드 · ⌘ 그대로 보내기")
    private let savedLabel = UILabel()
    private let savedList = DeskListView()
    private let hintLabel = UILabel()
    private var saved: [VNCClient.Server] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: 0x16171B)
        scrollView.indicatorStyle = .white
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        addSubview(scrollView)

        titleLabel.text = "원격 데스크톱 연결"
        titleLabel.textColor = Theme.text
        subtitleLabel.text = "내 PC·Mac·미니PC·클라우드 PC의 화면을 모니터에 띄우고, 그 안의 모든 앱을 사용하세요."
        subtitleLabel.textColor = Theme.secondaryText
        subtitleLabel.numberOfLines = 0
        for label in [titleLabel, subtitleLabel] { scrollView.addSubview(label) }

        portField.text = "5900"
        portField.keyboardType = .numbersAndPunctuation
        hostField.keyboardType = .URL
        passwordField.isSecure = true
        nameField.inputDescription = "이름"
        hostField.inputDescription = "주소"
        portField.inputDescription = "포트"
        passwordField.inputDescription = "비밀번호"
        hostField.onSubmit = { [weak self] _ in self?.submit() }
        passwordField.onSubmit = { [weak self] _ in self?.submit() }
        for field in [nameField, hostField, portField, passwordField] { scrollView.addSubview(field) }

        connectButton.normalBackground = Theme.accent
        connectButton.hoverBackground = Theme.accent.withAlphaComponent(0.85)
        connectButton.tint = .white
        connectButton.fontSize = 14
        connectButton.onTap = { [weak self] in self?.submit() }
        scrollView.addSubview(connectButton)
        macKeyboardButton.onTap = { [weak self] in
            guard let self else { return }; self.macKeyboardButton.isToggled.toggle()
        }
        scrollView.addSubview(macKeyboardButton)

        savedLabel.text = "저장된 연결"
        savedLabel.textColor = Theme.secondaryText
        scrollView.addSubview(savedLabel)
        savedList.rowHeight = 46
        savedList.onActivate = { [weak self] index in self?.connectSaved(index) }
        savedList.activatesOnSingleClick = true
        savedList.onContextMenu = { [weak self] index, event in self?.savedMenu(index, at: event.location) }
        scrollView.addSubview(savedList)

        hintLabel.numberOfLines = 0
        hintLabel.textColor = Theme.tertiaryText
        hintLabel.text = "• Windows: TightVNC·UltraVNC·RealVNC 서버 설치\n• Mac: 시스템 설정 › 일반 › 공유 › 화면 공유 켜기 → 'VNC 사용자가…'에서 비밀번호 설정\n• Linux: x11vnc 또는 TigerVNC\n• 외부: 양쪽 Tailscale을 켜고 Mac의 100.x.x.x 주소 사용\n• 연결에 성공한 암호는 이 기기의 키체인에 저장됩니다"
        scrollView.addSubview(hintLabel)
        reloadSaved()
        if let first = saved.first { fill(first) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reloadSaved() {
        saved = VNCServerStore.all()
        savedList.items = saved.map { server in
            DeskListItem(title: server.name, subtitle: "\(server.host):\(server.port)", detail: nil,
                         symbol: "display", tint: UIColor(hex: 0x58A6FF))
        }
        savedLabel.isHidden = saved.isEmpty
        savedList.isHidden = saved.isEmpty
        setNeedsLayout()
    }

    private func submit() {
        let host = hostField.text.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            DeskSession.shared.desktop?.showToast("주소를 입력하세요", symbol: "exclamationmark.triangle")
            return
        }
        let port = Int(portField.text.trimmingCharacters(in: .whitespaces)) ?? 5900
        let name = nameField.text.trimmingCharacters(in: .whitespaces)
        let server = VNCClient.Server(name: name.isEmpty ? host : name, host: host, port: port, password: passwordField.text, macKeyboard: macKeyboardButton.isToggled)
        onConnect?(server)
    }

    private func connectSaved(_ index: Int) {
        guard saved.indices.contains(index) else { return }
        let server = saved[index]
        fill(server)
        if server.password.isEmpty {
            DeskSession.shared.desktop?.setKeyFocus(passwordField)
            DeskSession.shared.desktop?.showToast("Mac에서 설정한 VNC 암호를 입력하세요", symbol: "lock")
        } else { onConnect?(server) }
    }

    private func fill(_ server: VNCClient.Server) {
        nameField.text = server.name; hostField.text = server.host; portField.text = String(server.port)
        passwordField.text = server.password; macKeyboardButton.isToggled = server.macKeyboard
    }

    private func savedMenu(_ index: Int?, at point: CGPoint) {
        guard let index, saved.indices.contains(index) else { return }
        let server = saved[index]
        DeskSession.shared.desktop?.showContextMenu([
            MenuItem(title: "연결", symbol: "bolt.fill") { [weak self] in self?.connectSaved(index) },
            MenuItem(title: "삭제", symbol: "trash", isDestructive: true) { [weak self] in
                VNCServerStore.remove(host: server.host, port: server.port)
                self?.reloadSaved()
            },
        ], at: point)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let width = min(bounds.width - Theme.s(48), Theme.s(460))
        let x = (bounds.width - width) / 2
        var y = Theme.s(28)
        titleLabel.font = Theme.font(20, .bold)
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: Theme.s(28))
        y += Theme.s(34)
        subtitleLabel.font = Theme.font(13)
        let subtitleHeight = ceil(subtitleLabel.sizeThatFits(CGSize(width: width, height: 200)).height)
        subtitleLabel.frame = CGRect(x: x, y: y, width: width, height: subtitleHeight)
        y += subtitleHeight + Theme.s(18)

        let fieldHeight = Theme.s(38)
        nameField.frame = CGRect(x: x, y: y, width: width, height: fieldHeight)
        y += fieldHeight + Theme.s(8)
        hostField.frame = CGRect(x: x, y: y, width: width * 0.62 - Theme.s(4), height: fieldHeight)
        portField.frame = CGRect(x: x + width * 0.62 + Theme.s(4), y: y, width: width * 0.38 - Theme.s(4), height: fieldHeight)
        y += fieldHeight + Theme.s(8)
        passwordField.frame = CGRect(x: x, y: y, width: width, height: fieldHeight)
        y += fieldHeight + Theme.s(12)
        macKeyboardButton.frame = CGRect(x: x, y: y, width: width, height: Theme.s(32))
        y += Theme.s(40)
        connectButton.frame = CGRect(x: x, y: y, width: width, height: Theme.s(42))
        y += Theme.s(42) + Theme.s(22)

        if !saved.isEmpty {
            savedLabel.font = Theme.font(12, .semibold)
            savedLabel.frame = CGRect(x: x, y: y, width: width, height: Theme.s(18))
            y += Theme.s(24)
            let listHeight = Theme.s(CGFloat(saved.count) * 46 + 8)
            savedList.frame = CGRect(x: x, y: y, width: width, height: listHeight)
            y += listHeight + Theme.s(20)
        }
        hintLabel.font = Theme.font(12)
        let hintHeight = ceil(hintLabel.sizeThatFits(CGSize(width: width, height: 400)).height)
        hintLabel.frame = CGRect(x: x, y: y, width: width, height: hintHeight)
        y += hintHeight + Theme.s(28)
        scrollView.contentSize = CGSize(width: bounds.width, height: y)
    }
}
