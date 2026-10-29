import UIKit
import PDFKit
import AVFoundation
import ImageIO

/// Bottom toolbar shared by the viewers.
private final class ViewerToolbar: UIView {
    let label = UILabel()
    private var leading: [DeskButton] = []
    private var trailing: [DeskButton] = []

    init(leading: [DeskButton], trailing: [DeskButton]) {
        self.leading = leading
        self.trailing = trailing
        super.init(frame: .zero)
        backgroundColor = Theme.panel
        label.textColor = Theme.secondaryText
        label.textAlignment = .center
        addSubview(label)
        for button in leading + trailing {
            button.symbolSize = 14
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = Theme.s(30)
        let y = (bounds.height - size) / 2
        var x = Theme.s(8)
        for button in leading {
            button.frame = CGRect(x: x, y: y, width: size, height: size)
            x += size + Theme.s(2)
        }
        var right = bounds.width - Theme.s(8)
        for button in trailing.reversed() {
            right -= size
            button.frame = CGRect(x: right, y: y, width: size, height: size)
            right -= Theme.s(2)
        }
        label.font = Theme.font(12)
        label.frame = CGRect(x: x + Theme.s(8), y: 0, width: max(0, right - x - Theme.s(16)), height: bounds.height)
    }
}

// MARK: - Images

final class ImageViewerContent: AppContentView, KeyInputTarget {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let previousButton = DeskButton(symbol: "chevron.left")
    private let nextButton = DeskButton(symbol: "chevron.right")
    private let zoomOutButton = DeskButton(symbol: "minus.magnifyingglass")
    private let fitButton = DeskButton(symbol: "arrow.up.left.and.down.right.magnifyingglass")
    private let zoomInButton = DeskButton(symbol: "plus.magnifyingglass")
    private let toolbar: ViewerToolbar
    private var images: [URL] = []
    private var index = 0
    private var zoom: CGFloat = 1

    init(fileURL: URL?) {
        toolbar = ViewerToolbar(leading: [previousButton, nextButton], trailing: [zoomOutButton, fitButton, zoomInButton])
        super.init(frame: .zero)
        backgroundColor = UIColor(hex: 0x111214)
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.indicatorStyle = .white
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
        addSubview(toolbar)
        previousButton.onTap = { [weak self] in self?.step(-1) }
        nextButton.onTap = { [weak self] in self?.step(1) }
        zoomOutButton.onTap = { [weak self] in self?.setZoom((self?.zoom ?? 1) / 1.25) }
        zoomInButton.onTap = { [weak self] in self?.setZoom((self?.zoom ?? 1) * 1.25) }
        fitButton.onTap = { [weak self] in self?.setZoom(1) }
        if let fileURL {
            images = FileStore.contents(of: fileURL.deletingLastPathComponent()).filter { $0.kind == .image }.map { $0.url }
            index = images.firstIndex { $0.lastPathComponent == fileURL.lastPathComponent } ?? 0
            if images.isEmpty { images = [fileURL] }
        }
        loadCurrent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? { self }

    static func loadImage(_ url: URL) -> UIImage? {
        guard url.pathExtension.lowercased() == "gif",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 1 else {
            return UIImage(contentsOfFile: url.path)
        }
        var frames: [UIImage] = []
        var duration: Double = 0
        for frame in 0..<min(CGImageSourceGetCount(source), 400) {
            guard let image = CGImageSourceCreateImageAtIndex(source, frame, nil) else { continue }
            frames.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += delay < 0.02 ? 0.1 : delay
        }
        return frames.isEmpty ? nil : UIImage.animatedImage(with: frames, duration: duration)
    }

    private func loadCurrent() {
        guard images.indices.contains(index) else {
            title = "사진 보기"
            toolbar.label.text = "이미지가 없습니다"
            return
        }
        let url = images[index]
        imageView.image = ImageViewerContent.loadImage(url)
        title = url.lastPathComponent
        var info = "\(index + 1) / \(images.count)  ·  \(url.lastPathComponent)"
        if let size = imageView.image?.size {
            info += "  ·  \(Int(size.width * (imageView.image?.scale ?? 1)))×\(Int(size.height * (imageView.image?.scale ?? 1)))"
        }
        toolbar.label.text = info
        previousButton.isEnabled = images.count > 1
        nextButton.isEnabled = images.count > 1
        zoom = 1
        setNeedsLayout()
    }

    private func step(_ delta: Int) {
        guard !images.isEmpty else { return }
        index = (index + delta + images.count) % images.count
        loadCurrent()
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), 8)
        layoutImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barHeight = Theme.s(40)
        toolbar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        scrollView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
        layoutImage()
    }

    private func layoutImage() {
        let area = scrollView.bounds.size
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0, area.width > 0 else {
            imageView.frame = CGRect(origin: .zero, size: area)
            return
        }
        // Fit to the window, but never blow small images up past 100%.
        let fit = min(area.width / image.size.width, area.height / image.size.height, 1)
        let size = CGSize(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
        let center = CGPoint(x: scrollView.contentOffset.x + area.width / 2, y: scrollView.contentOffset.y + area.height / 2)
        let oldSize = scrollView.contentSize
        imageView.frame = CGRect(x: max(0, (area.width - size.width) / 2), y: max(0, (area.height - size.height) / 2), width: size.width, height: size.height)
        scrollView.contentSize = CGSize(width: max(area.width, size.width), height: max(area.height, size.height))
        // Keep the visible center stable while zooming.
        if oldSize.width > 0, oldSize.height > 0 {
            let ratioX = scrollView.contentSize.width / oldSize.width
            let ratioY = scrollView.contentSize.height / oldSize.height
            let offset = CGPoint(x: center.x * ratioX - area.width / 2, y: center.y * ratioY - area.height / 2)
            let maxX = max(0, scrollView.contentSize.width - area.width)
            let maxY = max(0, scrollView.contentSize.height - area.height)
            scrollView.contentOffset = CGPoint(x: min(max(0, offset.x), maxX), y: min(max(0, offset.y), maxY))
        }
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "=", "+": setZoom(zoom * 1.25)
        case "-": setZoom(zoom / 1.25)
        case "0": setZoom(1)
        default: return false
        }
        return true
    }

    var acceptsTextInput: Bool { false }
    var inputDescription: String { "사진 보기" }

    func insertText(_ text: String) {
        switch text {
        case "+", "=": setZoom(zoom * 1.25)
        case "-": setZoom(zoom / 1.25)
        case "0": setZoom(1)
        case " ": step(1)
        default: break
        }
    }

    func deleteBackward() {}

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        switch key {
        case .left, .pageUp: step(-1)
        case .right, .pageDown: step(1)
        case .up: _ = scrollView.deskScroll(by: CGPoint(x: 0, y: -Theme.s(60)))
        case .down: _ = scrollView.deskScroll(by: CGPoint(x: 0, y: Theme.s(60)))
        default: break
        }
    }
}

// MARK: - PDF

final class PDFViewerContent: AppContentView, KeyInputTarget {
    private let pdfView = PDFView()
    private let previousButton = DeskButton(symbol: "chevron.up")
    private let nextButton = DeskButton(symbol: "chevron.down")
    private let zoomOutButton = DeskButton(symbol: "minus.magnifyingglass")
    private let fitButton = DeskButton(symbol: "arrow.up.left.and.down.right.magnifyingglass")
    private let zoomInButton = DeskButton(symbol: "plus.magnifyingglass")
    private let toolbar: ViewerToolbar

    init(fileURL: URL?) {
        toolbar = ViewerToolbar(leading: [previousButton, nextButton], trailing: [zoomOutButton, fitButton, zoomInButton])
        super.init(frame: .zero)
        backgroundColor = UIColor(hex: 0x2A2B30)
        pdfView.backgroundColor = UIColor(hex: 0x2A2B30)
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = true
        if let fileURL { pdfView.document = PDFDocument(url: fileURL) }
        addSubview(pdfView)
        addSubview(toolbar)
        previousButton.onTap = { [weak self] in self?.pdfView.goToPreviousPage(nil) }
        nextButton.onTap = { [weak self] in self?.pdfView.goToNextPage(nil) }
        zoomOutButton.onTap = { [weak self] in self?.zoom(by: 1 / 1.2) }
        zoomInButton.onTap = { [weak self] in self?.zoom(by: 1.2) }
        fitButton.onTap = { [weak self] in self?.pdfView.autoScales = true }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        title = fileURL?.lastPathComponent ?? "PDF 보기"
        pageChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? { self }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barHeight = Theme.s(40)
        toolbar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        pdfView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
    }

    @objc private func pageChanged() {
        guard let document = pdfView.document else {
            toolbar.label.text = "PDF를 열 수 없습니다"
            return
        }
        let current = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        toolbar.label.text = "\(current) / \(document.pageCount) 페이지"
    }

    private func zoom(by factor: CGFloat) {
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(pdfView.scaleFactor * factor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
    }

    private var innerScrollView: UIScrollView? {
        pdfView.subviews.compactMap { $0 as? UIScrollView }.first
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "=", "+": zoom(by: 1.2)
        case "-": zoom(by: 1 / 1.2)
        case "0": pdfView.autoScales = true
        default: return false
        }
        return true
    }

    var acceptsTextInput: Bool { false }
    var inputDescription: String { "PDF 보기" }

    func insertText(_ text: String) {
        if text == " " { pdfView.goToNextPage(nil) }
    }

    func deleteBackward() {}

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        switch key {
        case .left, .pageUp: pdfView.goToPreviousPage(nil)
        case .right, .pageDown: pdfView.goToNextPage(nil)
        case .up: _ = innerScrollView?.deskScroll(by: CGPoint(x: 0, y: -Theme.s(60)))
        case .down: _ = innerScrollView?.deskScroll(by: CGPoint(x: 0, y: Theme.s(60)))
        case .home: pdfView.goToFirstPage(nil)
        case .end: pdfView.goToLastPage(nil)
        default: break
        }
    }

    override func willClose() {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Video & audio

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Clicks on the picture toggle playback; double-clicks toggle fullscreen.
private final class PlayerSurface: UIView, PointerTarget {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    func pointerDown(_ event: PointerEvent) -> Bool {
        guard event.button == .left else { return false }
        if event.clickCount == 2 { onDoubleClick?() }
        return true
    }

    func pointerUp(_ event: PointerEvent) {
        if event.clickCount == 1 { onClick?() }
    }
}

final class MediaPlayerContent: AppContentView, KeyInputTarget {
    private let player: AVPlayer?
    private let surface = PlayerSurface()
    private let videoView = PlayerLayerView()
    private let artwork = UIImageView()
    private let controls = UIView()
    private let playButton = DeskButton(symbol: "pause.fill")
    private let rewindButton = DeskButton(symbol: "gobackward.10")
    private let forwardButton = DeskButton(symbol: "goforward.10")
    private let fullscreenButton = DeskButton(symbol: "arrow.up.left.and.arrow.down.right")
    private let slider = DeskSlider()
    private let timeLabel = UILabel()
    private let isAudio: Bool
    private var timer: Timer?
    private(set) var isFullscreen = false

    init(fileURL: URL?) {
        player = fileURL.map { AVPlayer(url: $0) }
        isAudio = fileURL.map { FileStore.kind(of: $0) == .audio } ?? false
        super.init(frame: .zero)
        backgroundColor = .black
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.isUserInteractionEnabled = false
        surface.addSubview(videoView)
        artwork.image = UIImage(systemName: "music.note")
        artwork.tintColor = UIColor(white: 1, alpha: 0.5)
        artwork.contentMode = .scaleAspectFit
        artwork.isHidden = !isAudio
        artwork.isUserInteractionEnabled = false
        surface.addSubview(artwork)
        surface.onClick = { [weak self] in self?.togglePlay() }
        surface.onDoubleClick = { [weak self] in self?.toggleFullscreen() }
        addSubview(surface)
        controls.backgroundColor = Theme.panel.withAlphaComponent(0.95)
        addSubview(controls)
        for button in [rewindButton, playButton, forwardButton, fullscreenButton] {
            button.symbolSize = 15
            controls.addSubview(button)
        }
        playButton.onTap = { [weak self] in self?.togglePlay() }
        rewindButton.onTap = { [weak self] in self?.skip(by: -10) }
        forwardButton.onTap = { [weak self] in self?.skip(by: 10) }
        fullscreenButton.onTap = { [weak self] in self?.toggleFullscreen() }
        fullscreenButton.isHidden = isAudio
        slider.onChange = { [weak self] value in self?.seek(toFraction: value) }
        controls.addSubview(slider)
        timeLabel.textColor = Theme.secondaryText
        timeLabel.textAlignment = .right
        controls.addSubview(timeLabel)
        title = fileURL?.lastPathComponent ?? "미디어 플레이어"
        timer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        player?.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? { self }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barHeight = Theme.s(48)
        controls.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        surface.frame = isFullscreen ? bounds : CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
        videoView.frame = surface.bounds
        let artworkSize = min(surface.bounds.width, surface.bounds.height) * 0.35
        artwork.frame = CGRect(x: (surface.bounds.width - artworkSize) / 2, y: (surface.bounds.height - artworkSize) / 2, width: artworkSize, height: artworkSize)
        if isFullscreen { bringSubviewToFront(controls) }
        let size = Theme.s(34)
        let y = (barHeight - size) / 2
        var x = Theme.s(8)
        for button in [rewindButton, playButton, forwardButton] {
            button.frame = CGRect(x: x, y: y, width: size, height: size)
            x += size + Theme.s(2)
        }
        fullscreenButton.frame = CGRect(x: bounds.width - size - Theme.s(8), y: y, width: size, height: size)
        timeLabel.font = Theme.monoFont(12)
        let timeWidth = Theme.s(116)
        let timeRight = isAudio ? bounds.width - Theme.s(10) : fullscreenButton.frame.minX - Theme.s(8)
        timeLabel.frame = CGRect(x: timeRight - timeWidth, y: 0, width: timeWidth, height: barHeight)
        slider.frame = CGRect(x: x + Theme.s(10), y: 0, width: max(0, timeLabel.frame.minX - x - Theme.s(20)), height: barHeight)
    }

    private var duration: Double {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%ld:%02ld:%02ld", hours, minutes, secs) : String(format: "%ld:%02ld", minutes, secs)
    }

    @objc private func tick() {
        guard let player else { return }
        let current = player.currentTime().seconds
        if !slider.isDragging, duration > 0 {
            slider.value = current / duration
        }
        timeLabel.text = "\(MediaPlayerContent.format(current)) / \(MediaPlayerContent.format(duration))"
        let playing = player.timeControlStatus != .paused
        let symbol = playing ? "pause.fill" : "play.fill"
        if playButton.symbolName != symbol { playButton.symbolName = symbol }
    }

    private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            if duration > 0 && player.currentTime().seconds >= duration - 0.3 {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
        tick()
    }

    private func skip(by seconds: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        player.seek(to: CMTime(seconds: duration > 0 ? min(target, duration) : target, preferredTimescale: 600))
    }

    private func seek(toFraction fraction: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func toggleFullscreen() {
        guard !isAudio, let window = deskWindow, let desktop else { return }
        isFullscreen.toggle()
        desktop.setWindowFullscreen(window, isFullscreen)
        fullscreenButton.symbolName = isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        setNeedsLayout()
    }

    override func exitFullscreen() {
        if isFullscreen { toggleFullscreen() }
    }

    var acceptsTextInput: Bool { false }
    var inputDescription: String { "미디어 플레이어" }

    func insertText(_ text: String) {
        switch text.lowercased() {
        case " ", "k": togglePlay()
        case "f": toggleFullscreen()
        case "j": skip(by: -10)
        case "l": skip(by: 10)
        case "m": player?.isMuted.toggle()
        default: break
        }
    }

    func deleteBackward() {}

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        guard let player else { return }
        switch key {
        case .left: skip(by: -5)
        case .right: skip(by: 5)
        case .up: player.volume = min(1, player.volume + 0.1)
        case .down: player.volume = max(0, player.volume - 0.1)
        case .enter: toggleFullscreen()
        default: break
        }
    }

    override func willClose() {
        timer?.invalidate()
        timer = nil
        player?.pause()
    }
}
