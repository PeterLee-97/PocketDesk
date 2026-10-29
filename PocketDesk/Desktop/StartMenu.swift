import UIKit

/// App launcher opened from the taskbar's start button (or ⌘/Ctrl + Esc).
final class StartMenuView: UIView, PointerTarget {
    weak var desktop: DesktopViewController?
    let searchField = DeskTextField(placeholder: "앱 검색 · 웹 주소 · 검색어를 입력하세요")

    private let appsLabel = UILabel()
    private let webLabel = UILabel()
    private var appTiles: [StartTile] = []
    private var webTiles: [StartTile] = []
    private let footerLine = UIView()
    private let helpButton = DeskButton(symbol: "questionmark.circle", title: "도움말")
    private let settingsButton = DeskButton(symbol: "gearshape", title: "설정")
    private let showDesktopButton = DeskButton(symbol: "menubar.dock.rectangle", title: "바탕화면 보기")
    private let closeAllButton = DeskButton(symbol: "xmark.rectangle", title: "모든 창 닫기")
    private let hintLabel = UILabel()
    private var filter = ""

    init(desktop: DesktopViewController) {
        self.desktop = desktop
        super.init(frame: .zero)
        backgroundColor = Theme.panel.withAlphaComponent(0.98)
        layer.borderWidth = 1
        layer.borderColor = Theme.border.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 30
        layer.shadowOffset = CGSize(width: 0, height: 10)

        searchField.fontSize = 14
        searchField.keyboardType = .webSearch
        searchField.inputDescription = "시작 메뉴 검색"
        searchField.onChange = { [weak self] text in
            self?.filter = text.trimmingCharacters(in: .whitespaces)
            self?.setNeedsLayout()
        }
        searchField.onSubmit = { [weak self] text in self?.submit(text) }
        searchField.onEscape = { [weak self] in self?.desktop?.closeStartMenu() }
        addSubview(searchField)

        for label in [appsLabel, webLabel, hintLabel] {
            label.textColor = Theme.secondaryText
            addSubview(label)
        }
        appsLabel.text = "앱"
        webLabel.text = "웹 바로가기"
        hintLabel.text = "검색어를 입력하고 Enter를 누르면 웹에서 검색합니다"
        hintLabel.textColor = Theme.tertiaryText

        for kind in AppKind.launcher {
            let tile = StartTile(style: kind.iconStyle, title: kind.title)
            tile.onTap = { [weak self] in
                self?.desktop?.closeStartMenu()
                self?.desktop?.open(kind)
            }
            appTiles.append(tile)
            addSubview(tile)
        }
        for shortcut in Settings.shared.shortcuts {
            let tile = StartTile(style: ShortcutIcons.style(for: shortcut), title: shortcut.title)
            tile.onTap = { [weak self] in
                self?.desktop?.closeStartMenu()
                if let url = URL(string: shortcut.url) { self?.desktop?.openWeb(url) }
            }
            webTiles.append(tile)
            addSubview(tile)
        }

        footerLine.backgroundColor = Theme.separator
        addSubview(footerLine)
        for button in [helpButton, settingsButton, showDesktopButton, closeAllButton] {
            button.fontSize = 12.5
            button.symbolSize = 13
            addSubview(button)
        }
        helpButton.onTap = { [weak self] in
            self?.desktop?.closeStartMenu()
            self?.desktop?.open(.help)
        }
        settingsButton.onTap = { [weak self] in
            self?.desktop?.closeStartMenu()
            self?.desktop?.open(.settings)
        }
        showDesktopButton.onTap = { [weak self] in
            self?.desktop?.closeStartMenu()
            self?.desktop?.minimizeAll()
        }
        closeAllButton.onTap = { [weak self] in
            self?.desktop?.closeStartMenu()
            self?.desktop?.closeAllWindows()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func matches(_ tile: StartTile) -> Bool {
        filter.isEmpty || (tile.title ?? "").localizedCaseInsensitiveContains(filter)
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let tile = (appTiles + webTiles).first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(trimmed) }) {
            tile.onTap?()
            return
        }
        desktop?.closeStartMenu()
        desktop?.openUserInput(trimmed)
    }

    static func preferredSize(in bounds: CGSize) -> CGSize {
        CGSize(width: min(Theme.s(620), bounds.width - Theme.s(16)), height: min(Theme.s(560), bounds.height - Theme.s(80)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Theme.s(14)
        let padding = Theme.s(20)
        let width = bounds.width - padding * 2
        searchField.frame = CGRect(x: padding, y: padding, width: width, height: Theme.s(38))
        var y = searchField.frame.maxY + Theme.s(18)

        let columns = 6
        let cell = floor(width / CGFloat(columns))
        let tileHeight = cell * 1.0

        func layoutGrid(_ tiles: [StartTile], label: UILabel) {
            let visible = tiles.filter(matches)
            for tile in tiles where !visible.contains(where: { $0 === tile }) { tile.isHidden = true }
            label.isHidden = visible.isEmpty
            guard !visible.isEmpty else { return }
            label.font = Theme.font(12, .semibold)
            label.frame = CGRect(x: padding + Theme.s(4), y: y, width: width, height: Theme.s(18))
            y += Theme.s(24)
            for (index, tile) in visible.enumerated() {
                tile.isHidden = false
                let column = index % columns
                let row = index / columns
                tile.frame = CGRect(x: padding + CGFloat(column) * cell, y: y + CGFloat(row) * tileHeight, width: cell, height: tileHeight)
            }
            y += CGFloat((visible.count + columns - 1) / columns) * tileHeight + Theme.s(14)
        }
        layoutGrid(appTiles, label: appsLabel)
        layoutGrid(webTiles, label: webLabel)

        hintLabel.font = Theme.font(12)
        hintLabel.isHidden = filter.isEmpty
        hintLabel.frame = CGRect(x: padding + Theme.s(4), y: y, width: width, height: Theme.s(20))

        let footerHeight = Theme.s(50)
        footerLine.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: 1)
        var x = padding - Theme.s(6)
        for button in [helpButton, settingsButton, showDesktopButton, closeAllButton] {
            let buttonWidth = button.preferredWidth()
            button.frame = CGRect(x: x, y: bounds.height - footerHeight + Theme.s(9), width: buttonWidth, height: Theme.s(32))
            x += buttonWidth + Theme.s(4)
        }
    }

    func pointerDown(_ event: PointerEvent) -> Bool { true }
}

/// Icon + caption tile used by the start menu.
final class StartTile: DeskButton {
    private let tile: IconTileView

    init(style: IconTileView.Style, title: String) {
        self.tile = IconTileView(style: style)
        super.init(title: title)
        fontSize = 12
        titleLabel.textAlignment = .center
        addSubview(tile)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = min(bounds.width * 0.5, bounds.height * 0.5)
        tile.frame = CGRect(x: (bounds.width - size) / 2, y: bounds.height * 0.13, width: size, height: size)
        let lineHeight = ceil(titleLabel.font.lineHeight)
        titleLabel.frame = CGRect(x: Theme.s(3), y: tile.frame.maxY + Theme.s(7), width: bounds.width - Theme.s(6), height: lineHeight)
    }
}
