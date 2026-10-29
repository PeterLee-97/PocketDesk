import UIKit
import GameController

/// Watches for Bluetooth keyboards and mice through the GameController framework.
///
/// Keyboard *text* still arrives through the phone's key sink (so the iOS input methods, e.g.
/// Korean, keep working); GameController is only used to know a keyboard is present and which
/// modifier keys are held during clicks. Mouse support is best-effort: iPhone may only deliver
/// GCMouse events on some iOS versions.
final class HardwareInput: NSObject {
    static let shared = HardwareInput()
    static let didChange = Notification.Name("PocketDeskHardwareInputDidChange")

    private(set) var hasKeyboard = false
    private(set) var hasMouse = false
    private var mice: [GCMouse] = []

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidConnect, object: nil)
        center.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidDisconnect, object: nil)
        center.addObserver(self, selector: #selector(mouseConnected(_:)), name: .GCMouseDidConnect, object: nil)
        center.addObserver(self, selector: #selector(mouseDisconnected(_:)), name: .GCMouseDidDisconnect, object: nil)
        hasKeyboard = GCKeyboard.coalesced != nil
        GCMouse.mice().forEach(attach)
    }

    /// Modifier keys currently held on a hardware keyboard (for ⌘-click, ⇧-click, …).
    var currentModifiers: KeyModifiers {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return [] }
        func pressed(_ code: GCKeyCode) -> Bool { input.button(forKeyCode: code)?.isPressed ?? false }
        var modifiers: KeyModifiers = []
        if pressed(.leftShift) || pressed(.rightShift) { modifiers.insert(.shift) }
        if pressed(.leftControl) || pressed(.rightControl) { modifiers.insert(.control) }
        if pressed(.leftAlt) || pressed(.rightAlt) { modifiers.insert(.option) }
        if pressed(.leftGUI) || pressed(.rightGUI) { modifiers.insert(.command) }
        return modifiers
    }

    @objc private func keyboardChanged() {
        hasKeyboard = GCKeyboard.coalesced != nil
        NotificationCenter.default.post(name: HardwareInput.didChange, object: self)
    }

    @objc private func mouseConnected(_ notification: Notification) {
        if let mouse = notification.object as? GCMouse { attach(mouse) }
    }

    @objc private func mouseDisconnected(_ notification: Notification) {
        if let mouse = notification.object as? GCMouse { mice.removeAll { $0 === mouse } }
        hasMouse = !mice.isEmpty
        NotificationCenter.default.post(name: HardwareInput.didChange, object: self)
    }

    private func attach(_ mouse: GCMouse) {
        guard !mice.contains(where: { $0 === mouse }), let input = mouse.mouseInput else { return }
        mice.append(mouse)
        hasMouse = true
        input.mouseMovedHandler = { _, deltaX, deltaY in
            let speed = CGFloat(Settings.shared.pointerSpeed)
            // GameController reports +Y as "up"; screen coordinates grow downwards.
            DeskSession.shared.movePointer(dx: CGFloat(deltaX) * speed, dy: CGFloat(-deltaY) * speed)
        }
        input.leftButton.pressedChangedHandler = { _, _, pressed in
            DeskSession.shared.setButton(.left, pressed: pressed)
        }
        input.rightButton?.pressedChangedHandler = { _, _, pressed in
            DeskSession.shared.setButton(.right, pressed: pressed)
        }
        input.middleButton?.pressedChangedHandler = { _, _, pressed in
            DeskSession.shared.setButton(.middle, pressed: pressed)
        }
        input.scroll.valueChangedHandler = { _, x, y in
            // Wheel "up" (+Y) scrolls the content back, like a desktop mouse.
            DeskSession.shared.scroll(dx: CGFloat(-x) * 30, dy: CGFloat(-y) * 30)
        }
        NotificationCenter.default.post(name: HardwareInput.didChange, object: self)
    }
}
