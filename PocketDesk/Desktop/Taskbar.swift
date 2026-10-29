import UIKit

/// Bottom bar: start button, pinned/running apps, battery and clock.
final class TaskbarView: UIView, PointerTarget {
    weak var desktop: DesktopViewController?
    let startButton = DeskButton(symbol: "square.grid.2x2.fill")

    private var appButtons: [AppKind: TaskbarAppButton] = [:]
    private var order: [AppKind] = []
    private let separator = UIView()
    private let clockLabel = UILabel()
    private let dateLabel = UILabel()
    private let batteryIcon = UIImageView()
    private let batteryLabel = UILabel()
    private let trayButton = DeskButton()
    private let topLine = UIView()
    private var clockTimer: Timer?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 (E)"
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.taskbar
        startButton.symbolSize = 17
        startButton.tint = Theme.accent
        startButton.toggledBackground = Theme.pressed
        startButton.onTap = { [weak self] in self?.desktop?.toggleStartMenu() }
        addSubview(startButton)
        separator.backgroundColor = Theme.separator
        addSubview(separator)
        addSubview(trayButton)
        trayButton.onTap = { [weak self] in self?.desktop?.open(.settings) }
        for view in [batteryIcon, batteryLabel, clockLabel, dateLabel] as [UIView] {
            view.isUserInteractionEnabled = false
            trayButton.addSubview(view)
        }
        batteryIcon.contentMode = .center
        batteryIcon.tintColor = Theme.text
        batteryLabel.textColor = Theme.text
        clockLabel.textColor = Theme.text
        clockLabel.textAlignment = .right
        dateLabel.textColor = Theme.secondaryText
        dateLabel.textAlignment = .right
        topLine.backgroundColor = Theme.separator
        addSubview(topLine)
        updateClock()
        updateBattery()
        clockTimer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(updateClock), userInfo: nil, repeats: true)
        NotificationCenter.default.addObserver(self, selector: #selector(updateBattery), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateBattery), name: UIDevice.batteryStateDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func updateClock() {
        let now = Date()
        clockLabel.text = TaskbarView.timeFormatter.string(from: now)
        dateLabel.text = TaskbarView.dateFormatter.string(from: now)
    }

    @objc private func updateBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel
        guard level >= 0 else {
            batteryIcon.image = Theme.symbol("battery.100", size: 15)
            batteryLabel.text = ""
            setNeedsLayout()
            return
        }
        let charging = device.batteryState == .charging || device.batteryState == .full
        let name: String
        if charging {
            name = "battery.100.bolt"
        } else if level > 0.87 {
            name = "battery.100"
        } else if level > 0.62 {
            name = "battery.75"
        } else if level > 0.37 {
            name = "battery.50"
        } else if level > 0.12 {
            name = "battery.25"
        } else {
            name = "battery.0"
        }
        batteryIcon.image = Theme.symbol(name, size: 15)
        batteryIcon.tintColor = (!charging && level <= 0.2) ? Theme.danger : Theme.text
        batteryLabel.text = "\(Int((level * 100).rounded()))%"
        setNeedsLayout()
    }

    func update(windows: [DeskWindow], active: DeskWindow?) {
        let running = Set(windows.map { $0.kind })
        let kinds = AppKind.pinned + AppKind.allCases.filter { !AppKind.pinned.contains($0) && running.contains($0) }
        for kind in Array(appButtons.keys) where !kinds.contains(kind) {
            appButtons[kind]?.removeFromSuperview()
            appButtons[kind] = nil
        }
        for kind in kinds where appButtons[kind] == nil {
            let button = TaskbarAppButton(kind: kind)
            button.onTap = { [weak self] in self?.desktop?.taskbarAppClicked(kind) }
            button.onContextMenu = { [weak self] event in self?.desktop?.showTaskbarMenu(for: kind, at: event.location) }
            appButtons[kind] = button
            addSubview(button)
        }
        order = kinds
        for kind in kinds {
            guard let button = appButtons[kind] else { continue }
            button.windowCount = windows.filter { $0.kind == kind }.count
            button.isActiveApp = active?.kind == kind
        }
        setNeedsLayout()
    }

    /// Center of the taskbar button for `kind`, in the taskbar's coordinates (for minimize animations).
    func buttonCenter(for kind: AppKind) -> CGPoint? {
        appButtons[kind].map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        topLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        let padding = Theme.s(5)
        let item = bounds.height - padding * 2
        startButton.frame = CGRect(x: Theme.s(8), y: padding, width: item, height: item)
        separator.frame = CGRect(x: startButton.frame.maxX + Theme.s(7), y: bounds.height * 0.25, width: 1, height: bounds.height * 0.5)
        var x = separator.frame.maxX + Theme.s(7)
        for kind in order {
            appButtons[kind]?.frame = CGRect(x: x, y: padding, width: item, height: item)
            x += item + Theme.s(3)
        }

        clockLabel.font = Theme.font(12.5, .medium)
        dateLabel.font = Theme.font(10.5)
        batteryLabel.font = Theme.font(12)
        let clockWidth = max(clockLabel.sizeThatFits(.zero).width, dateLabel.sizeThatFits(.zero).width)
        let batteryLabelWidth = batteryLabel.sizeThatFits(.zero).width
        let iconWidth = batteryIcon.image?.size.width ?? 0
        let trayWidth = Theme.s(12) + iconWidth + Theme.s(4) + batteryLabelWidth + Theme.s(14) + clockWidth + Theme.s(12)
        trayButton.frame = CGRect(x: bounds.width - trayWidth - Theme.s(6), y: padding, width: trayWidth, height: item)
        var trayX = Theme.s(12)
        batteryIcon.frame = CGRect(x: trayX, y: 0, width: iconWidth, height: item)
        trayX += iconWidth + Theme.s(4)
        batteryLabel.frame = CGRect(x: trayX, y: 0, width: batteryLabelWidth, height: item)
        trayX += batteryLabelWidth + Theme.s(14)
        let lineHeight = item / 2 - Theme.s(2)
        clockLabel.frame = CGRect(x: trayX, y: Theme.s(3), width: clockWidth, height: lineHeight)
        dateLabel.frame = CGRect(x: trayX, y: Theme.s(3) + lineHeight, width: clockWidth, height: lineHeight)
    }

    // Clicks on empty taskbar space shouldn't fall through to the desktop.
    func pointerDown(_ event: PointerEvent) -> Bool { true }
}

final class TaskbarAppButton: DeskButton {
    let kind: AppKind
    var windowCount = 0 { didSet { stateChanged() } }
    var isActiveApp = false { didSet { stateChanged() } }
    var onContextMenu: ((PointerEvent) -> Void)?

    private let tile: IconTileView
    private let indicator = UIView()

    init(kind: AppKind) {
        self.kind = kind
        self.tile = IconTileView(style: kind.iconStyle)
        super.init()
        toggledBackground = UIColor(white: 1, alpha: 0.09)
        addSubview(tile)
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)
    }

    private func stateChanged() {
        isToggled = isActiveApp && windowCount > 0
        setNeedsLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.height * 0.6
        tile.frame = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2 - Theme.s(1.5), width: size, height: size)
        indicator.isHidden = windowCount == 0
        let width = isActiveApp ? bounds.width * 0.38 : Theme.s(6)
        let height = Theme.s(3)
        indicator.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - height - Theme.s(1.5), width: width, height: height)
        indicator.layer.cornerRadius = height / 2
        indicator.backgroundColor = isActiveApp ? Theme.accent : UIColor(white: 1, alpha: 0.55)
    }

    override func pointerDown(_ event: PointerEvent) -> Bool {
        if event.button == .right {
            onContextMenu?(event)
            return true
        }
        return super.pointerDown(event)
    }
}
