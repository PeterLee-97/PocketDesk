import UIKit

/// Desktop look & metrics. All desktop views lay themselves out in `layoutSubviews` using
/// `Theme.s(_:)` and `Theme.font(_:_:)`, so changing `scale` only needs a relayout.
enum Theme {
    static var scale: CGFloat = 1
    static let didChange = Notification.Name("PocketDeskThemeDidChange")

    static func s(_ value: CGFloat) -> CGFloat {
        (value * scale * 2).rounded() / 2
    }

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size * scale, weight: weight)
    }

    static func monoFont(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size * scale, weight: weight)
    }

    static func symbol(_ name: String, size: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: size * scale, weight: weight)
        return UIImage(systemName: name, withConfiguration: configuration)
    }

    static let accent = UIColor(hex: 0x4A8FFF)
    static let text = UIColor(white: 0.95, alpha: 1)
    static let secondaryText = UIColor(white: 0.62, alpha: 1)
    static let tertiaryText = UIColor(white: 0.45, alpha: 1)
    static let windowBackground = UIColor(hex: 0x1C1D21)
    static let panel = UIColor(hex: 0x26272C)
    static let titleBarActive = UIColor(hex: 0x2B2C32)
    static let titleBarInactive = UIColor(hex: 0x202125)
    static let field = UIColor(white: 0, alpha: 0.32)
    static let separator = UIColor(white: 1, alpha: 0.08)
    static let border = UIColor(white: 1, alpha: 0.13)
    static let hover = UIColor(white: 1, alpha: 0.08)
    static let pressed = UIColor(white: 1, alpha: 0.16)
    static let selection = UIColor(hex: 0x4A8FFF, alpha: 0.38)
    static let danger = UIColor(hex: 0xEE4545)
    static let taskbar = UIColor(hex: 0x111216, alpha: 0.9)
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

struct Wallpaper {
    let name: String
    let colors: [UIColor]

    static let presets: [Wallpaper] = [
        Wallpaper(name: "새벽", colors: [UIColor(hex: 0x141E46), UIColor(hex: 0x2B4C9B), UIColor(hex: 0x5FA8D3)]),
        Wallpaper(name: "노을", colors: [UIColor(hex: 0x2D1B4E), UIColor(hex: 0x8E3B6F), UIColor(hex: 0xF08A5D)]),
        Wallpaper(name: "숲", colors: [UIColor(hex: 0x0B2B26), UIColor(hex: 0x1C5D4A), UIColor(hex: 0x6FAF7A)]),
        Wallpaper(name: "바다", colors: [UIColor(hex: 0x002B4E), UIColor(hex: 0x006D8F), UIColor(hex: 0x3CC3C8)]),
        Wallpaper(name: "흑연", colors: [UIColor(hex: 0x111214), UIColor(hex: 0x2A2C31), UIColor(hex: 0x4A4E57)]),
        Wallpaper(name: "라벤더", colors: [UIColor(hex: 0x2E2A5A), UIColor(hex: 0x6B5CA5), UIColor(hex: 0xC3A6E0)]),
    ]
}

extension UIView {
    /// Re-runs `layoutSubviews` for the whole subtree (used after a theme scale change).
    func setNeedsLayoutRecursively() {
        setNeedsLayout()
        for subview in subviews { subview.setNeedsLayoutRecursively() }
    }

    var enclosingDeskWindow: DeskWindow? {
        var view: UIView? = self
        while let current = view {
            if let window = current as? DeskWindow { return window }
            view = current.superview
        }
        return nil
    }

    func firstAncestor<T>(ofType type: T.Type) -> T? {
        var view: UIView? = self
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}

/// A container that only reports hits on its subviews, never on itself.
class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
