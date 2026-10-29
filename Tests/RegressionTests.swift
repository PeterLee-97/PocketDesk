import XCTest
import UIKit
import WebKit
import AVFoundation
@testable import PocketDesk

@MainActor
final class RegressionTests: XCTestCase {
    private var host: UIWindow!
    private var browser: BrowserContent!

    override func setUp() {
        super.setUp()
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        host = UIWindow(windowScene: scene)
        host.rootViewController = UIViewController()
        host.makeKeyAndVisible()
        browser = BrowserContent(url: URL(string: "about:blank"), configuration: BrowserEnvironment.makeConfiguration())
        browser.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        host.rootViewController!.view.addSubview(browser)
        browser.layoutIfNeeded()
    }

    override func tearDown() {
        browser.willClose()
        browser.removeFromSuperview()
        browser = nil
        host.isHidden = true
        host = nil
        DeskSession.shared.displayDidDisconnect()
        super.tearDown()
    }

    private var web: WKWebView { browser.currentTab!.webView }
    private func js(_ source: String, bridge: Bool = false) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.__evaluateJavaScript(source, inFrame: nil, in: bridge ? BrowserEnvironment.world : .page) { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    private func load(_ content: String) async throws {
        web.loadHTMLString("<!doctype html><html><head></head><body id='fixture' style='margin:0'>\(content)</body></html>", baseURL: URL(string: "https://fixture.invalid"))
        try await eventually("document.readyState === 'complete' && !!document.getElementById('fixture')")
    }
    private func eventually(_ condition: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<150 {
            if (try? await js(condition)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTFail("Timed out: \(condition)", file: file, line: line)
    }

    func testViewportFollowsWindowWidthAndUserZoomIgnoresChromeScale() async throws {
        try await load("<div style='width:100%;height:40px;background:blue'></div>")
        try await eventually("Math.abs(document.documentElement.clientWidth - 600) < 3")
        browser.frame.size.width = 1050
        browser.setNeedsLayout(); browser.layoutIfNeeded()
        try await eventually("Math.abs(document.documentElement.clientWidth - 1050) < 3")
        browser.frame.size.width = 420
        browser.setNeedsLayout(); browser.layoutIfNeeded()
        try await eventually("Math.abs(document.documentElement.clientWidth - 420) < 3")
        let scale = Theme.scale
        defer { Theme.scale = scale }
        Theme.scale = 2
        browser.currentTab!.applyZoom()
        XCTAssertEqual(web.pageZoom, 1, accuracy: 0.001)
        browser.pinchZoom(by: 1.5)
        XCTAssertEqual(web.pageZoom, 1.5, accuracy: 0.001)
        browser.smartZoom()
        XCTAssertEqual(web.pageZoom, 1, accuracy: 0.001)
    }

    func testOneVirtualTapClicksWebButtonExactlyOnce() async throws {
        try await load("<button id='b' style='width:200px;height:100px' onclick='window.clicks=(window.clicks||0)+1'>Play</button>")
        _ = try await js("__pd.downCSS(60,40,'left',1,{});__pd.upCSS(60,40,{})", bridge: true)
        let count = try await js("window.clicks") as? Int
        XCTAssertEqual(count, 1)
    }

    func testBackspaceAndForwardDeleteAreDistinctIncludingKorean() async throws {
        XCTAssertEqual(KeyboardSinkView.deletionKey(for: .keyboardDeleteOrBackspace), .backspace)
        XCTAssertEqual(KeyboardSinkView.deletionKey(for: .keyboardDeleteForward), .deleteForward)
        try await load("<input id='edit' value='가나다'>")
        _ = try await js("var e=document.getElementById('edit');e.focus();e.setSelectionRange(2,2)")
        _ = try await js("__pd.key('Backspace',{})", bridge: true)
        var value = try await js("document.getElementById('edit').value") as? String
        XCTAssertEqual(value, "가다")
        _ = try await js("__pd.key('Delete',{})", bridge: true)
        value = try await js("document.getElementById('edit').value") as? String
        XCTAssertEqual(value, "가")
        let field = DeskTextField(placeholder: "test")
        field.text = "가나다"
        field.handleSpecialKey(.end, modifiers: [])
        field.handleSpecialKey(.backspace, modifiers: [])
        XCTAssertEqual(field.text, "가나")
    }

    func testEmptyKeyboardBufferStillForwardsBackspace() async throws {
        try await load("<input id='edit' value='한글테스트'>")
        _ = try await js("var e=document.getElementById('edit');e.focus();e.setSelectionRange(e.value.length,e.value.length)")
        let desktop = DeskSession.shared.makeOrReuseDesktop()
        desktop.loadViewIfNeeded()
        DeskSession.shared.displayDidConnect(windowScene: host.windowScene!)
        desktop.setKeyFocus(browser.currentTab!.keyTarget)
        let sink = KeyboardSinkView()
        sink.clearBuffer()
        sink.deleteBackward()
        try await eventually("document.getElementById('edit').value === '한글테스'")
    }

    func testFullscreenHasNativeEscapeAndRestoresWindow() {
        let desktop = DesktopViewController()
        desktop.loadViewIfNeeded()
        desktop.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        desktop.viewDidLayoutSubviews()
        let window = desktop.open(.calculator)
        let before = window.frame
        desktop.setWindowFullscreen(window, true)
        XCTAssertTrue(window.isFullscreen)
        XCTAssertFalse(desktop.fullscreenExitButton.isHidden)
        XCTAssertTrue(desktop.rootView.bounds.contains(desktop.fullscreenExitButton.frame))
        let exit = desktop.fullscreenExitButton.center
        desktop.movePointer(by: CGPoint(x: exit.x - desktop.cursorLocation.x, y: exit.y - desktop.cursorLocation.y))
        desktop.pointerButton(.left, pressed: true)
        desktop.pointerButton(.left, pressed: false)
        XCTAssertFalse(window.isFullscreen)
        XCTAssertFalse(window.isChromeHidden)
        XCTAssertTrue(desktop.fullscreenExitButton.isHidden)
        XCTAssertEqual(window.frame, before)
        desktop.closeAllWindows()
    }

    func testFullscreenExitReachesEmbeddedVideo() async throws {
        try await load("<iframe id='f' srcdoc=\"<video id='v'></video>\"></iframe>")
        _ = try await js("document.getElementById('f').contentDocument.getElementById('v').requestFullscreen();true")
        try await eventually("!!document.getElementById('f').contentDocument.fullscreenElement")
        _ = try await js("window.__pdExitFullscreen();true")
        try await eventually("!document.getElementById('f').contentDocument.fullscreenElement")
    }

    func testSingleClickOpensDesktopIconOnlyOnce() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let icon = DesktopIconView(style: AppKind.browser.iconStyle, title: "Internet")
        icon.frame = CGRect(x: 0, y: 0, width: 120, height: 120); root.addSubview(icon)
        var opened = 0
        icon.onOpen = { opened += 1 }
        for count in 1...2 {
            let event = PointerEvent(location: CGPoint(x: 30, y: 30), button: .left, clickCount: count, modifiers: [], root: root)
            _ = icon.pointerDown(event); icon.pointerUp(event)
        }
        XCTAssertEqual(opened, 1)
    }

    func testPinchNeverTurnsIntoScrollOrRightClick() {
        var gesture = MultiFingerGesture()
        gesture.begin(points: [CGPoint(x: 50,y: 100), CGPoint(x: 150,y: 100)])
        guard case .pinch(let factor) = gesture.update(points: [CGPoint(x: 30,y: 100), CGPoint(x: 170,y: 100)]) else { return XCTFail("Pinch not recognized") }
        XCTAssertEqual(factor, 1.4, accuracy: 0.001)
        XCTAssertFalse(gesture.isTap)
        XCTAssertFalse(gesture.isScroll)
        guard case .none = gesture.update(points: [CGPoint(x: 40,y: 100)]) else { return XCTFail("Lifting a finger must not scroll") }
    }

    func testScrollAndWindowSwipeAreSeparate() {
        var gesture = MultiFingerGesture()
        gesture.begin(points: [CGPoint(x: 50,y: 100), CGPoint(x: 150,y: 100)])
        guard case .scroll(let delta) = gesture.update(points: [CGPoint(x: 50,y: 120), CGPoint(x: 150,y: 120)]) else { return XCTFail("Scroll not recognized") }
        XCTAssertEqual(delta.y, 20)
        gesture.begin(points: [CGPoint(x: 10,y: 20), CGPoint(x: 20,y: 20), CGPoint(x: 30,y: 20)])
        guard case .swipe(let movement) = gesture.update(points: [CGPoint(x: 70,y: 20), CGPoint(x: 80,y: 20), CGPoint(x: 90,y: 20)]) else { return XCTFail("Window swipe not recognized") }
        XCTAssertEqual(movement.x, 60)
        guard case .none = gesture.update(points: [CGPoint(x: 80,y: 20), CGPoint(x: 90,y: 20), CGPoint(x: 100,y: 20)]) else { return XCTFail("One switch per gesture") }
    }

    func testVNCCredentialsMigrateToKeychainAndStayOutOfPreferences() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "vncServers")
        let host = "regression-\(UUID().uuidString).invalid"
        defer {
            VNCServerStore.remove(host: host, port: 5900)
            defaults.set(previous, forKey: "vncServers")
        }
        defaults.set([["name":"Fixture", "host":host, "port":5900, "password":"test1234", "macKeyboard":true]], forKey: "vncServers")
        let migrated = VNCServerStore.all()
        XCTAssertEqual(migrated.first?.password, "test1234")
        XCTAssertEqual(migrated.first?.macKeyboard, true)
        XCTAssertNil((defaults.array(forKey: "vncServers") as? [[String:Any]])?.first?["password"])
        var server = migrated[0]; server.password = "new12345"
        VNCServerStore.save(server)
        XCTAssertEqual(VNCServerStore.all().first?.password, "new12345")
        XCTAssertNil((defaults.array(forKey: "vncServers") as? [[String:Any]])?.first?["password"])
    }

    func testHangulPanelComposesAndDeletesJamoWithoutLosingFinals() {
        var composer = HangulComposer()
        for (keys, expected) in [("ㅎㅏㄴㄱㅡㄹ", "한글"), ("ㄱㅏㄴㅏ", "가나"), ("ㄷㅏㄹㄱㅏ", "달가"), ("ㅇㅓㅂㅅㅇㅓ", "없어"), ("ㄲㅏㅆ", "깠")] {
            composer.reset()
            keys.forEach { composer.append($0) }
            XCTAssertEqual(composer.text, expected)
        }
        composer.reset()
        "ㄱㅗㅏㅇ".forEach { composer.append($0) }
        XCTAssertEqual(composer.text, "광")
        for expected in ["과", "고", "ㄱ", ""] {
            composer.delete(); XCTAssertEqual(composer.text, expected)
        }
    }

    func testLanguageSwitchPreservesComposedTextAndUsesInstalledInputModes() async throws {
        try await load("<input id='edit' value=''>")
        _ = try await js("document.getElementById('edit').focus()")
        let desktop = DeskSession.shared.makeOrReuseDesktop()
        desktop.loadViewIfNeeded()
        DeskSession.shared.displayDidConnect(windowScene: host.windowScene!)
        desktop.setKeyFocus(browser.currentTab!.keyTarget)
        let sink = KeyboardSinkView()
        host.rootViewController!.view.addSubview(sink)
        XCTAssertNotNil(KeyboardSinkView.availableMode(for: .korean), "Test simulator needs the Korean keyboard")
        XCTAssertNotNil(KeyboardSinkView.availableMode(for: .english), "Test simulator needs the English keyboard")
        XCTAssertTrue(sink.becomeFirstResponder())
        XCTAssertTrue(sink.selectInputLanguage(.korean))
        XCTAssertEqual(KeyboardSinkView.InputLanguage(primaryLanguage: sink.textInputMode?.primaryLanguage), .korean)
        sink.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        sink.textViewDidChange(sink)
        try await eventually("document.getElementById('edit').value === '한'")
        XCTAssertTrue(sink.selectInputLanguage(.english))
        XCTAssertNil(sink.markedTextRange)
        XCTAssertTrue(sink.isFirstResponder)
        XCTAssertEqual(KeyboardSinkView.InputLanguage(primaryLanguage: sink.textInputMode?.primaryLanguage), .english)
        sink.insertText("a"); sink.textViewDidChange(sink)
        try await eventually("document.getElementById('edit').value === '한a'")
        sink.resignFirstResponder()
    }

    func testPhoneKeyboardButtonOpensWhileInputAlreadyHasFocusAndTypesBothLanguages() async throws {
        let originalPhone = DeskSession.shared.phone
        defer { DeskSession.shared.phone = originalPhone }
        let desktop = DeskSession.shared.makeOrReuseDesktop()
        desktop.loadViewIfNeeded()
        DeskSession.shared.displayDidConnect(windowScene: host.windowScene!)
        let field = DeskTextField(placeholder: "test")
        desktop.setKeyFocus(field)
        let phone = PhoneViewController()
        host.rootViewController = phone
        phone.loadViewIfNeeded()
        phone.view.layoutIfNeeded()
        func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }
        func button(_ id: String) throws -> UIButton {
            try XCTUnwrap(allViews(phone.view).first { $0.accessibilityIdentifier == id } as? UIButton)
        }
        let sink = try XCTUnwrap(allViews(phone.view).compactMap { $0 as? KeyboardSinkView }.first)
        _ = sink.becomeFirstResponder()
        let toggle = try button("keyboard.show")
        toggle.sendActions(for: .primaryActionTriggered)
        phone.view.layoutIfNeeded()
        let panel = try XCTUnwrap(allViews(phone.view).compactMap { $0 as? OnscreenKeyboardView }.first)
        XCTAssertFalse(panel.isHidden, "Hardware input focus must not prevent the phone keyboard opening")
        XCTAssertEqual(toggle.accessibilityValue, "열림")
        if panel.language != .korean { try button("keyboard.language.toolbar").sendActions(for: .primaryActionTriggered) }
        XCTAssertEqual(panel.language, .korean)
        for key in ["ㅎ", "ㅏ", "ㄴ", "ㄱ", "ㅡ", "ㄹ"] {
            try button("keyboard.key." + key).sendActions(for: .primaryActionTriggered)
        }
        XCTAssertEqual(field.text, "한글")
        try button("keyboard.key.⌫").sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(field.text, "한그", "One tap deletes one jamo, not two")
        try button("keyboard.key.한/영").sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(panel.language, .english)
        try button("keyboard.key.a").sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(field.text, "한그a")
        phone.view.layoutIfNeeded()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        func capture(_ name: String) throws {
            let renderer = UIGraphicsImageRenderer(bounds: phone.view.bounds)
            let data = renderer.pngData { _ in phone.view.drawHierarchy(in: phone.view.bounds, afterScreenUpdates: true) }
            try data.write(to: documents.appendingPathComponent(name))
        }
        try capture("keyboard-portrait.png")
        phone.view.bounds.size = CGSize(width: 852, height: 393)
        phone.view.setNeedsLayout(); phone.view.layoutIfNeeded()
        phone.view.setNeedsLayout(); phone.view.layoutIfNeeded()
        XCTAssertGreaterThan(panel.bounds.height, 100)
        XCTAssertTrue(phone.view.bounds.contains(panel.convert(panel.bounds, to: phone.view)))
        try capture("keyboard-landscape.png")
        try button("keyboard.key.닫기").sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(panel.isHidden)
        XCTAssertEqual(field.text, "한그a")
    }

    func testFocusAndLanguageChangesNeverOpenPhoneKeyboard() throws {
        let originalPhone = DeskSession.shared.phone
        let defaults = UserDefaults.standard
        let oldAutoShow = defaults.object(forKey: "autoShowKeyboard")
        defaults.set(true, forKey: "autoShowKeyboard") // Older installations may retain this setting.
        defer {
            DeskSession.shared.phone = originalPhone
            if let oldAutoShow { defaults.set(oldAutoShow, forKey: "autoShowKeyboard") }
            else { defaults.removeObject(forKey: "autoShowKeyboard") }
        }
        let desktop = DeskSession.shared.makeOrReuseDesktop()
        desktop.loadViewIfNeeded()
        DeskSession.shared.displayDidConnect(windowScene: host.windowScene!)
        let phone = PhoneViewController()
        host.rootViewController = phone
        phone.loadViewIfNeeded()
        phone.view.layoutIfNeeded()
        func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }
        let views = allViews(phone.view)
        let sink = try XCTUnwrap(views.compactMap { $0 as? KeyboardSinkView }.first)
        let panel = try XCTUnwrap(views.compactMap { $0 as? OnscreenKeyboardView }.first)
        let toggle = try XCTUnwrap(views.first { $0.accessibilityIdentifier == "keyboard.show" } as? UIButton)
        let language = try XCTUnwrap(views.first { $0.accessibilityIdentifier == "keyboard.language.toolbar" } as? UIButton)
        let field = DeskTextField(placeholder: "test")
        desktop.setKeyFocus(field)
        phone.keyFocusDidChange()
        XCTAssertTrue(panel.isHidden)
        XCTAssertTrue(sink.isFirstResponder, "Hardware keyboard must remain usable while panel is closed")
        XCTAssertNotNil(sink.inputView, "Never fall back to the system onscreen keyboard")
        XCTAssertNil(sink.inputAccessoryView)
        language.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(panel.isHidden, "Changing language must not open the phone keyboard")
        XCTAssertTrue(sink.selectInputLanguage(.english))
        XCTAssertTrue(sink.handleHardwareKey(.keyboardLANG1, modifiers: []))
        XCTAssertEqual(sink.inputLanguage, .korean)
        XCTAssertTrue(panel.isHidden)
        for code: UIKeyboardHIDUsage in [.keyboardG, .keyboardK, .keyboardS, .keyboardR, .keyboardM, .keyboardF] {
            XCTAssertTrue(sink.handleHardwareKey(code, modifiers: []))
        }
        XCTAssertEqual(field.text, "한글", "Physical keys must type Korean, not just change a button label")
        XCTAssertTrue(sink.handleHardwareKey(.keyboardSpacebar, modifiers: .control))
        XCTAssertEqual(sink.inputLanguage, .english)
        XCTAssertTrue(sink.handleHardwareKey(.keyboardA, modifiers: []))
        XCTAssertEqual(field.text, "한글a")
        XCTAssertTrue(panel.isHidden)
        toggle.sendActions(for: .primaryActionTriggered)
        XCTAssertFalse(panel.isHidden)
        desktop.setKeyFocus(DeskTextField(placeholder: "other"))
        phone.keyFocusDidChange()
        XCTAssertFalse(panel.isHidden, "Focus changes must preserve the explicit keyboard state")
        toggle.sendActions(for: .primaryActionTriggered)
        phone.phoneDidBecomeActive()
        NotificationCenter.default.post(name: HardwareInput.didChange, object: nil)
        desktop.setKeyFocus(field)
        phone.keyFocusDidChange()
        XCTAssertTrue(panel.isHidden, "Closing must persist across clicks, resume and keyboard connection changes")
        XCTAssertTrue(sink.isFirstResponder)
        XCTAssertFalse(sink.handleHardwareKey(.keyboardA, modifiers: .command), "Keep editing shortcuts")
        XCTAssertFalse(sink.handleHardwareKey(.keyboardSpacebar, modifiers: [.control, .alternate]))
        XCTAssertNil(KeyboardSinkView.hardwareLetter(.keyboardReturnOrEnter, modifiers: [], language: .korean))
        XCTAssertEqual(KeyboardSinkView.hardwareLetter(.keyboardR, modifiers: .shift, language: .korean), "ㄲ")
    }

    func testMediaPlaysInlineAndExplicitSoundActionUnmutes() async throws {
        PlaybackAudio.shared.activate()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertTrue(web.configuration.allowsInlineMediaPlayback)
        XCTAssertTrue(web.configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
        var data = Data()
        func text(_ s: String) { data.append(Data(s.utf8)) }
        func u16(_ n: UInt16) { var v=n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var v=n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let samples = 16000
        text("RIFF");u32(UInt32(36 + samples * 2));text("WAVEfmt ");u32(16);u16(1);u16(1);u32(8000);u32(16000);u16(2);u16(16);text("data");u32(UInt32(samples * 2))
        for i in 0..<samples { u16(UInt16(bitPattern: Int16(sin(Double(i)*2*Double.pi*440/8000)*1000))) }
        try await load("<video id='v' muted autoplay loop src='data:audio/wav;base64,\(data.base64EncodedString())'></video>")
        try await eventually("document.getElementById('v').currentTime > 0 && !document.getElementById('v').paused")
        _ = try await js("window.__pdEnableSound();true")
        try await eventually("!document.getElementById('v').muted && document.getElementById('v').volume > 0")
        let inline = try await js("document.getElementById('v').playsInline") as? Bool
        XCTAssertEqual(inline, true)
    }
}
