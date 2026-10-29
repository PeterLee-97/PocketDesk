import UIKit

/// Glue between the phone screen (the input device) and the external display (the desktop).
final class DeskSession {
    static let shared = DeskSession()

    /// Kept alive across cable unplugs so open windows survive a reconnect.
    private(set) var desktop: DesktopViewController?
    private(set) var isDisplayConnected = false
    private(set) var displayDescription = ""
    weak var phone: PhoneViewController?

    private var activeDesktop: DesktopViewController? {
        isDisplayConnected ? desktop : nil
    }

    func makeOrReuseDesktop() -> DesktopViewController {
        if let desktop { return desktop }
        let created = DesktopViewController()
        desktop = created
        return created
    }

    func displayDidConnect(windowScene: UIWindowScene) {
        isDisplayConnected = true
        let pixels = windowScene.screen.nativeBounds.size
        displayDescription = "\(Int(max(pixels.width, pixels.height)))×\(Int(min(pixels.width, pixels.height)))"
        phone?.displayStateDidChange()
    }

    func displayDidDisconnect() {
        isDisplayConnected = false
        desktop?.cancelPointerInteraction()
        phone?.displayStateDidChange()
    }

    func phoneDidBecomeActive() {
        phone?.phoneDidBecomeActive()
    }

    func phoneWillResignActive() {
        desktop?.cancelPointerInteraction()
        phone?.phoneWillResignActive()
    }

    // MARK: Pointer input (trackpad, mouse)

    func movePointer(dx: CGFloat, dy: CGFloat) {
        activeDesktop?.movePointer(by: CGPoint(x: dx, y: dy))
    }

    func setButton(_ button: PointerButton, pressed: Bool) {
        activeDesktop?.pointerButton(button, pressed: pressed)
    }

    func click(_ button: PointerButton) {
        setButton(button, pressed: true)
        setButton(button, pressed: false)
    }

    func scroll(dx: CGFloat, dy: CGFloat) {
        activeDesktop?.scroll(by: CGPoint(x: dx, y: dy))
    }

    func zoom(by factor: CGFloat) { activeDesktop?.zoom(by: factor) }
    func smartZoom() { activeDesktop?.smartZoom() }
    func swipeWindows(horizontal: CGFloat, vertical: CGFloat) {
        activeDesktop?.swipeWindows(horizontal: horizontal, vertical: vertical)
    }
    func swipePage(horizontal: CGFloat) {
        guard let browser = activeDesktop?.activeWindow?.content as? BrowserContent else { return }
        browser.swipePage(horizontal: horizontal)
    }

    // MARK: Keyboard input (phone keyboard or Bluetooth keyboard via the key sink)

    func insertText(_ text: String) {
        activeDesktop?.keyboardInsertText(text)
    }

    func deleteBackward() {
        activeDesktop?.keyboardDeleteBackward()
    }

    func specialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        activeDesktop?.keyboardSpecialKey(key, modifiers: modifiers)
    }

    @discardableResult
    func shortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        activeDesktop?.keyboardShortcut(key, modifiers: modifiers) ?? false
    }

    // MARK: Desktop → phone

    var keyFocus: KeyInputTarget? { activeDesktop?.keyFocus }

    func keyFocusDidChange() {
        phone?.keyFocusDidChange()
    }

    func presentOnPhone(_ viewController: UIViewController) {
        phone?.presentFromDesktop(viewController)
    }
}
