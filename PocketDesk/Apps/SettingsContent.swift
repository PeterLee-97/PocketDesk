import UIKit
import PhotosUI

/// One labelled row in the settings list.
private final class SettingsRow: UIView {
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    let control: UIView
    let controlWidth: () -> CGFloat
    var height: CGFloat

    init(title: String, detail: String? = nil, control: UIView, height: CGFloat = 52, controlWidth: @escaping () -> CGFloat) {
        self.control = control
        self.controlWidth = controlWidth
        self.height = height
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 2
        detailLabel.text = detail
        detailLabel.textColor = Theme.secondaryText
        detailLabel.numberOfLines = 2
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(control)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.font = Theme.font(13.5)
        detailLabel.font = Theme.font(11.5)
        let width = min(controlWidth(), bounds.width * 0.62)
        let controlHeight = min(bounds.height - Theme.s(12), control is DeskToggle ? Theme.s(26) : Theme.s(32))
        if control is WallpaperPicker {
            control.frame = CGRect(x: Theme.s(16), y: Theme.s(34), width: bounds.width - Theme.s(32), height: bounds.height - Theme.s(40))
            titleLabel.frame = CGRect(x: Theme.s(16), y: Theme.s(6), width: bounds.width - Theme.s(32), height: Theme.s(24))
            detailLabel.isHidden = true
            return
        }
        control.frame = CGRect(x: bounds.width - width - Theme.s(16), y: (bounds.height - controlHeight) / 2, width: width, height: controlHeight)
        let textWidth = max(0, control.frame.minX - Theme.s(32))
        if (detailLabel.text ?? "").isEmpty {
            detailLabel.isHidden = true
            titleLabel.frame = CGRect(x: Theme.s(16), y: 0, width: textWidth, height: bounds.height)
        } else {
            detailLabel.isHidden = false
            titleLabel.frame = CGRect(x: Theme.s(16), y: Theme.s(7), width: textWidth, height: Theme.s(20))
            detailLabel.frame = CGRect(x: Theme.s(16), y: Theme.s(27), width: textWidth, height: bounds.height - Theme.s(31))
        }
    }
}

/// Gradient thumbnails plus a "photo" button.
private final class WallpaperPicker: UIView {
    var onPick: ((Int) -> Void)?
    var onPhoto: (() -> Void)?
    private var thumbs: [DeskButton] = []
    private var gradients: [CAGradientLayer] = []
    private let photoButton = DeskButton(symbol: "photo.on.rectangle", title: "사진에서 선택…")

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (index, wallpaper) in Wallpaper.presets.enumerated() {
            let button = DeskButton()
            let gradient = CAGradientLayer()
            gradient.colors = wallpaper.colors.map { $0.cgColor }
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            button.layer.insertSublayer(gradient, at: 0)
            button.clipsToBounds = true
            button.hoverBackground = .clear
            button.pressedBackground = .clear
            button.onTap = { [weak self] in self?.onPick?(index) }
            gradients.append(gradient)
            thumbs.append(button)
            addSubview(button)
        }
        photoButton.normalBackground = UIColor(white: 1, alpha: 0.08)
        photoButton.fontSize = 12.5
        photoButton.onTap = { [weak self] in self?.onPhoto?() }
        addSubview(photoButton)
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateSelection() {
        let selected = Settings.shared.wallpaperIndex
        for (index, thumb) in thumbs.enumerated() {
            thumb.layer.borderWidth = index == selected ? max(2, Theme.s(2.5)) : 1
            thumb.layer.borderColor = (index == selected ? Theme.accent : Theme.border).cgColor
        }
        photoButton.isToggled = selected < 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = Theme.s(54)
        let width = height * 16 / 10
        var x: CGFloat = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, thumb) in thumbs.enumerated() {
            thumb.frame = CGRect(x: x, y: 0, width: width, height: height)
            thumb.cornerRadius = 6
            gradients[index].frame = thumb.bounds
            x += width + Theme.s(8)
        }
        CATransaction.commit()
        let buttonWidth = photoButton.preferredWidth()
        photoButton.frame = CGRect(x: 0, y: height + Theme.s(10), width: buttonWidth, height: Theme.s(30))
        updateSelection()
    }
}

final class SettingsContent: AppContentView, PHPickerViewControllerDelegate {
    private let scrollView = UIScrollView()
    private var sections: [(UILabel, [SettingsRow])] = []
    private let wallpaperPicker = WallpaperPicker()
    private static let scaleValues: [Double] = [0, 0.9, 1, 1.25, 1.5, 1.75, 2]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.windowBackground
        scrollView.indicatorStyle = .white
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        title = "설정"
        buildSections()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func header(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.textColor = Theme.accent
        return label
    }

    private func buildSections() {
        let settings = Settings.shared

        let scaleIndex = SettingsContent.scaleValues.firstIndex(of: settings.uiScale) ?? 0
        let scale = DeskSegmented(titles: ["자동", "90%", "100%", "125%", "150%", "175%", "200%"], selectedIndex: scaleIndex)
        scale.onChange = { index in Settings.shared.uiScale = SettingsContent.scaleValues[index] }

        wallpaperPicker.onPick = { [weak self] index in
            Settings.shared.wallpaperIndex = index
            self?.wallpaperPicker.updateSelection()
        }
        wallpaperPicker.onPhoto = { [weak self] in self?.pickPhoto() }

        let speed = DeskSlider()
        speed.value = (settings.pointerSpeed - 0.4) / 2.6
        speed.onChange = { value in Settings.shared.pointerSpeed = 0.4 + value * 2.6 }

        let natural = DeskToggle()
        natural.isOn = settings.naturalScrolling
        natural.onChange = { Settings.shared.naturalScrolling = $0 }

        let haptics = DeskToggle()
        haptics.isOn = settings.haptics
        haptics.onChange = { Settings.shared.haptics = $0 }

        let autoKeyboard = DeskToggle()
        autoKeyboard.isOn = settings.autoShowKeyboard
        autoKeyboard.onChange = { Settings.shared.autoShowKeyboard = $0 }

        let desktopSites = DeskToggle()
        desktopSites.isOn = settings.desktopWebsites
        desktopSites.onChange = { Settings.shared.desktopWebsites = $0 }

        let engine = DeskSegmented(titles: SearchEngine.allCases.map { $0.name }, selectedIndex: settings.searchEngine.rawValue)
        engine.onChange = { index in Settings.shared.searchEngine = SearchEngine(rawValue: index) ?? .google }

        let home = DeskTextField(placeholder: "https://www.google.com")
        home.text = settings.homePage
        home.inputDescription = "시작 페이지 주소"
        home.keyboardType = .URL
        home.onSubmit = { [weak self, weak home] text in
            if let url = Settings.shared.url(fromUserInput: text) {
                Settings.shared.homePage = url.absoluteString
                home?.text = url.absoluteString
                self?.desktop?.showToast("시작 페이지를 저장했습니다", symbol: "checkmark.circle")
            }
        }

        let resetShortcuts = DeskButton(title: "기본값으로")
        resetShortcuts.normalBackground = UIColor(white: 1, alpha: 0.08)
        resetShortcuts.onTap = { [weak self] in
            Settings.shared.shortcuts = Settings.defaultShortcuts
            self?.desktop?.showToast("바탕화면 바로가기를 기본값으로 되돌렸습니다", symbol: "arrow.counterclockwise")
        }

        let display = DeskSession.shared.displayDescription.isEmpty ? "연결 안 됨" : DeskSession.shared.displayDescription
        let info = UILabel()
        info.text = "PocketDesk 1.0"
        info.textColor = Theme.secondaryText
        info.textAlignment = .right

        sections = [
            (header("디스플레이"), [
                SettingsRow(title: "화면 크기", detail: "글자와 창 크기 배율 (현재 모니터: \(display))", control: scale) { scale.preferredWidth() },
                SettingsRow(title: "배경화면", control: wallpaperPicker, height: 140) { 0 },
            ]),
            (header("포인터"), [
                SettingsRow(title: "트랙패드 · 마우스 속도", control: speed) { Theme.s(240) },
                SettingsRow(title: "자연스러운 스크롤", detail: "손가락 방향으로 내용이 움직입니다", control: natural) { Theme.s(46) },
                SettingsRow(title: "햅틱 피드백", detail: "클릭할 때 아이폰이 살짝 진동합니다", control: haptics) { Theme.s(46) },
            ]),
            (header("키보드"), [
                SettingsRow(title: "입력란을 누르면 아이폰 키보드 표시", detail: "블루투스 키보드가 연결되어 있으면 표시하지 않습니다", control: autoKeyboard) { Theme.s(46) },
            ]),
            (header("인터넷"), [
                SettingsRow(title: "데스크톱용 웹사이트", detail: "PC 화면용 페이지를 요청합니다", control: desktopSites) { Theme.s(46) },
                SettingsRow(title: "검색 엔진", control: engine) { engine.preferredWidth() },
                SettingsRow(title: "시작 페이지", detail: "입력 후 Enter", control: home) { Theme.s(280) },
                SettingsRow(title: "바탕화면 바로가기", control: resetShortcuts) { resetShortcuts.preferredWidth() },
            ]),
            (header("정보"), [
                SettingsRow(title: "버전", detail: "아이폰을 컴퓨터처럼 쓰는 데스크톱 모드", control: info) { Theme.s(160) },
            ]),
        ]
        for (label, rows) in sections {
            scrollView.addSubview(label)
            rows.forEach { scrollView.addSubview($0) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let width = min(bounds.width, Theme.s(760))
        let x = (bounds.width - width) / 2
        var y = Theme.s(18)
        for (label, rows) in sections {
            label.font = Theme.font(12.5, .semibold)
            label.frame = CGRect(x: x + Theme.s(16), y: y, width: width - Theme.s(32), height: Theme.s(20))
            y += Theme.s(26)
            for row in rows {
                let height = Theme.s(row.height)
                row.frame = CGRect(x: x, y: y, width: width, height: height)
                row.backgroundColor = Theme.panel
                row.layer.cornerRadius = Theme.s(8)
                y += height + Theme.s(2)
            }
            y += Theme.s(18)
        }
        scrollView.contentSize = CGSize(width: bounds.width, height: y)
    }

    // MARK: Wallpaper photo

    private func pickPhoto() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        DeskSession.shared.presentOnPhone(picker)
        desktop?.showToast("iPhone 화면에서 사진을 선택하세요", symbol: "iphone")
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage, let data = SettingsContent.wallpaperData(from: image) else { return }
            try? data.write(to: FileStore.wallpaperFile, options: .atomic)
            DispatchQueue.main.async {
                Settings.shared.wallpaperIndex = -1
                DeskSession.shared.desktop?.wallpaperImageDidChange()
            }
        }
    }

    /// Downscales to at most 4K and encodes as JPEG.
    private static func wallpaperData(from image: UIImage) -> Data? {
        let maxSide: CGFloat = 3840
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.88)
    }
}
