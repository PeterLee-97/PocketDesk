import UIKit

// The external display is non-interactive: iOS never delivers touches or key presses to it.
// Everything on the desktop is driven by these synthetic events, produced by the phone's
// trackpad, the keyboard sink and (when iOS allows it) a Bluetooth mouse.

enum PointerButton {
    case left, right, middle
}

struct KeyModifiers: OptionSet {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    init(flags: UIKeyModifierFlags) {
        var value: KeyModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.alternate) { value.insert(.option) }
        if flags.contains(.command) { value.insert(.command) }
        self = value
    }

    /// ⌘ on Apple keyboards and Ctrl on Windows keyboards both act as the shortcut key.
    var hasShortcutKey: Bool { contains(.command) || contains(.control) }

    /// Literal object passed to the injected web bridge.
    var jsObject: String {
        "{shift:\(contains(.shift)),ctrl:\(contains(.control)),alt:\(contains(.option)),meta:\(contains(.command))}"
    }
}

/// Non-character keys. Raw values match the DOM `KeyboardEvent.key` names.
enum SpecialKey: String {
    case enter = "Enter"
    case tab = "Tab"
    case escape = "Escape"
    case backspace = "Backspace"
    case deleteForward = "Delete"
    case left = "ArrowLeft"
    case right = "ArrowRight"
    case up = "ArrowUp"
    case down = "ArrowDown"
    case home = "Home"
    case end = "End"
    case pageUp = "PageUp"
    case pageDown = "PageDown"
}

enum CursorKind {
    case arrow, hand, text, move
    case resizeHorizontal, resizeVertical, resizeDiagonalDown, resizeDiagonalUp
}

struct PointerEvent {
    /// Location in desktop (root view) coordinates.
    let location: CGPoint
    let button: PointerButton
    let clickCount: Int
    let modifiers: KeyModifiers
    unowned let root: UIView

    func location(in view: UIView) -> CGPoint {
        root.convert(location, to: view)
    }
}

/// A view that reacts to the virtual mouse. Return `false` from `pointerDown` to let the
/// event continue to the superview.
protocol PointerTarget: AnyObject {
    func pointerDown(_ event: PointerEvent) -> Bool
    func pointerDragged(_ event: PointerEvent)
    func pointerUp(_ event: PointerEvent)
}

extension PointerTarget {
    func pointerDragged(_ event: PointerEvent) {}
    func pointerUp(_ event: PointerEvent) {}
}

protocol HoverTarget: AnyObject {
    func pointerEntered()
    func pointerMoved(_ event: PointerEvent)
    func pointerExited()
}

extension HoverTarget {
    func pointerEntered() {}
    func pointerMoved(_ event: PointerEvent) {}
    func pointerExited() {}
}

protocol ScrollTarget: AnyObject {
    /// Return `true` when the delta was consumed.
    func scroll(by delta: CGPoint, event: PointerEvent) -> Bool
}

protocol ZoomTarget: AnyObject {
    func zoom(by factor: CGFloat, event: PointerEvent)
    func smartZoom(event: PointerEvent)
}

protocol CursorProvider: AnyObject {
    /// `point` is in the receiver's coordinate space. Return nil to defer to the superview.
    func cursor(at point: CGPoint) -> CursorKind?
}

/// Receives keyboard input while it has the desktop's key focus.
protocol KeyInputTarget: AnyObject {
    func insertText(_ text: String)
    func deleteBackward()
    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers)
    func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool
    func keyFocusChanged(_ focused: Bool)
    /// Whether typing makes sense here (used to pop up the phone keyboard automatically).
    var acceptsTextInput: Bool { get }
    var keyboardType: UIKeyboardType { get }
    /// Short label shown on the phone so the user knows where typing goes.
    var inputDescription: String { get }
}

extension KeyInputTarget {
    func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool { false }
    func keyFocusChanged(_ focused: Bool) {}
    var acceptsTextInput: Bool { true }
    var keyboardType: UIKeyboardType { .default }
    var inputDescription: String { "" }
}

extension UIScrollView {
    /// Scrolls by `delta`, clamped to the content. Returns false when nothing moved so the
    /// event can bubble to an outer scroll view.
    func deskScroll(by delta: CGPoint) -> Bool {
        let inset = adjustedContentInset
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, contentSize.width - bounds.width + inset.right)
        let maxY = max(minY, contentSize.height - bounds.height + inset.bottom)
        let x = min(max(contentOffset.x + delta.x, minX), maxX)
        let y = min(max(contentOffset.y + delta.y, minY), maxY)
        if abs(x - contentOffset.x) < 0.01 && abs(y - contentOffset.y) < 0.01 { return false }
        setContentOffset(CGPoint(x: x, y: y), animated: false)
        return true
    }
}
