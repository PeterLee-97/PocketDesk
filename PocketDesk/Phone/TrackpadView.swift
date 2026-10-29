import UIKit

/// The phone's touchscreen as a laptop-style trackpad.
///
/// - 1 finger: move · tap: click · double-tap: double-click
/// - double-tap and hold (or long press), then move: drag
/// - 2 fingers: scroll (with momentum) · 2-finger tap: right click
/// - 3-finger tap: middle click
final class TrackpadView: UIView {
    var onFirstUse: (() -> Void)?

    private enum Mode { case idle, pointing, pressing, scrolling }

    private var mode: Mode = .idle
    private weak var primaryTouch: UITouch?
    private var touchStartTime: TimeInterval = 0
    private var moved: CGFloat = 0
    private var maxTouches = 0
    private var multiStartTime: TimeInterval = 0
    private var multiMoved: CGFloat = 0
    private var lastTapTime: TimeInterval = 0
    private var lastTapPoint: CGPoint = .zero
    private var buttonHeld = false
    private var lastMoveTime: TimeInterval = 0
    private var lastCentroid: CGPoint = .zero
    private var lastScrollTime: TimeInterval = 0
    private var scrollVelocity: CGPoint = .zero
    private var longPressTimer: Timer?
    private var inertiaLink: CADisplayLink?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Bigger displays need more travel per finger movement.
    private var sizeFactor: CGFloat {
        let width = DeskSession.shared.desktop?.rootView.bounds.width ?? 1920
        return min(max(width / 1500, 0.8), 2.6)
    }

    private func touches(of event: UIEvent?, fallback: Set<UITouch>) -> Set<UITouch> {
        let all = event?.touches(for: self) ?? fallback
        return all.filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    private func centroid(_ touches: Set<UITouch>) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        var sum = CGPoint.zero
        for touch in touches {
            let point = touch.location(in: self)
            sum.x += point.x
            sum.y += point.y
        }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopInertia()
        onFirstUse?()
        haptic.prepare()
        let active = self.touches(of: event, fallback: touches)
        maxTouches = max(maxTouches, active.count)
        if active.count == 1, let touch = touches.first {
            maxTouches = 1
            primaryTouch = touch
            touchStartTime = touch.timestamp
            lastMoveTime = touch.timestamp
            moved = 0
            let point = touch.location(in: self)
            let isSecondTap = touch.timestamp - lastTapTime < 0.3 && hypot(point.x - lastTapPoint.x, point.y - lastTapPoint.y) < 70
            if isSecondTap {
                // Hold the button right away: a quick release makes a double-click, moving makes a drag.
                press()
                mode = .pressing
            } else {
                mode = .pointing
                scheduleLongPress()
            }
        } else if active.count >= 2 {
            cancelLongPress()
            if buttonHeld { release() }
            if mode != .scrolling {
                multiStartTime = touches.first?.timestamp ?? 0
                multiMoved = 0
                scrollVelocity = .zero
            }
            mode = .scrolling
            lastCentroid = centroid(active)
            lastScrollTime = touches.first?.timestamp ?? 0
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = self.touches(of: event, fallback: touches)
        switch mode {
        case .pointing, .pressing:
            guard let touch = primaryTouch, touches.contains(touch) else { return }
            let point = touch.location(in: self)
            let previous = touch.previousLocation(in: self)
            let dx = point.x - previous.x
            let dy = point.y - previous.y
            moved += hypot(dx, dy)
            if moved > 10 { cancelLongPress() }
            let dt = max(touch.timestamp - lastMoveTime, 1.0 / 240)
            lastMoveTime = touch.timestamp
            let speed = hypot(dx, dy) / CGFloat(dt)
            let acceleration = 1 + min(speed / 900, 2.2)
            let gain = CGFloat(Settings.shared.pointerSpeed) * 1.5 * acceleration * sizeFactor
            DeskSession.shared.movePointer(dx: dx * gain, dy: dy * gain)
        case .scrolling:
            guard !active.isEmpty else { return }
            let center = centroid(active)
            let dx = center.x - lastCentroid.x
            let dy = center.y - lastCentroid.y
            lastCentroid = center
            multiMoved += hypot(dx, dy)
            guard multiMoved > 6 else { return }
            let direction: CGFloat = Settings.shared.naturalScrolling ? -1 : 1
            let gain = 1.7 * min(sizeFactor, 1.6)
            let delta = CGPoint(x: dx * direction * gain, y: dy * direction * gain)
            DeskSession.shared.scroll(dx: delta.x, dy: delta.y)
            let timestamp = touches.first?.timestamp ?? lastScrollTime
            let dt = max(timestamp - lastScrollTime, 1.0 / 240)
            lastScrollTime = timestamp
            let velocity = CGPoint(x: delta.x / CGFloat(dt), y: delta.y / CGFloat(dt))
            scrollVelocity = CGPoint(x: scrollVelocity.x * 0.6 + velocity.x * 0.4, y: scrollVelocity.y * 0.6 + velocity.y * 0.4)
        case .idle:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        let remaining = self.touches(of: event, fallback: []).subtracting(touches)
        switch mode {
        case .pointing:
            guard let touch = primaryTouch, touches.contains(touch) else { break }
            cancelLongPress()
            if !cancelled && touch.timestamp - touchStartTime < 0.3 && moved < 12 && maxTouches == 1 {
                click(.left)
                lastTapTime = touch.timestamp
                lastTapPoint = touch.location(in: self)
            }
            mode = .idle
        case .pressing:
            guard let touch = primaryTouch, touches.contains(touch) else { break }
            release()
            // A quick second tap counts as a tap too, so a third tap makes a triple-click.
            if touch.timestamp - touchStartTime < 0.3 && moved < 12 {
                lastTapTime = touch.timestamp
                lastTapPoint = touch.location(in: self)
            } else {
                lastTapTime = 0
            }
            mode = .idle
        case .scrolling:
            if remaining.isEmpty {
                let timestamp = touches.first?.timestamp ?? 0
                let duration = timestamp - multiStartTime
                if !cancelled && maxTouches == 2 && multiMoved < 10 && duration < 0.35 {
                    click(.right)
                } else if !cancelled && maxTouches >= 3 && multiMoved < 16 && duration < 0.4 {
                    click(.middle)
                } else if !cancelled && timestamp - lastScrollTime < 0.08 {
                    startInertia()
                }
                mode = .idle
                lastTapTime = 0
            } else {
                lastCentroid = centroid(remaining)
            }
        case .idle:
            break
        }
        if remaining.isEmpty {
            maxTouches = 0
            primaryTouch = nil
            if mode != .idle { mode = .idle }
            if buttonHeld { release() }
        }
    }

    // MARK: Buttons

    private func scheduleLongPress() {
        cancelLongPress()
        longPressTimer = Timer.scheduledTimer(timeInterval: 0.45, target: self, selector: #selector(longPressFired), userInfo: nil, repeats: false)
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    @objc private func longPressFired() {
        longPressTimer = nil
        guard mode == .pointing, moved < 10 else { return }
        press()
        mode = .pressing
        if Settings.shared.haptics { heavyHaptic.impactOccurred() }
    }

    private func press() {
        guard !buttonHeld else { return }
        buttonHeld = true
        DeskSession.shared.setButton(.left, pressed: true)
        buzz()
    }

    private func release() {
        guard buttonHeld else { return }
        buttonHeld = false
        DeskSession.shared.setButton(.left, pressed: false)
    }

    private func click(_ button: PointerButton) {
        DeskSession.shared.click(button)
        buzz()
    }

    private func buzz() {
        if Settings.shared.haptics { haptic.impactOccurred(intensity: 0.7) }
    }

    // MARK: Momentum scrolling

    private func startInertia() {
        guard hypot(scrollVelocity.x, scrollVelocity.y) > 120 else { return }
        stopInertia()
        let link = CADisplayLink(target: self, selector: #selector(inertiaStep(_:)))
        link.add(to: .main, forMode: .common)
        inertiaLink = link
    }

    @objc private func inertiaStep(_ link: CADisplayLink) {
        let dt = CGFloat(max(link.targetTimestamp - link.timestamp, 1.0 / 120))
        let decay = pow(0.94, dt * 60)
        scrollVelocity = CGPoint(x: scrollVelocity.x * decay, y: scrollVelocity.y * decay)
        guard hypot(scrollVelocity.x, scrollVelocity.y) > 30 else {
            stopInertia()
            return
        }
        DeskSession.shared.scroll(dx: scrollVelocity.x * dt, dy: scrollVelocity.y * dt)
    }

    func stopInertia() {
        inertiaLink?.invalidate()
        inertiaLink = nil
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopInertia()
            cancelLongPress()
            release()
        }
    }
}

/// Laptop-style click button below the trackpad (hold it and move with another finger to drag).
final class TrackpadButton: UIControl {
    private let button: PointerButton
    private let label = UILabel()
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(title: String, button: PointerButton) {
        self.button = button
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 1, alpha: 0.08)
        layer.cornerRadius = 14
        label.text = title
        label.textColor = UIColor(white: 1, alpha: 0.6)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        DeskSession.shared.setButton(button, pressed: true)
        backgroundColor = UIColor(white: 1, alpha: 0.2)
        if Settings.shared.haptics { haptic.impactOccurred(intensity: 0.7) }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        releaseButton()
    }

    override func cancelTracking(with event: UIEvent?) {
        releaseButton()
    }

    private func releaseButton() {
        DeskSession.shared.setButton(button, pressed: false)
        backgroundColor = UIColor(white: 1, alpha: 0.08)
    }
}
