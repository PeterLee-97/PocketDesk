import UIKit
import WebKit

/// Built-in desktop apps. (iOS doesn't let one app host another app's UI, so the desktop
/// ships its own browser, file manager, editors and viewers.)
enum AppKind: String, CaseIterable {
    case browser, files, notes, calculator, remoteDesktop, settings, help
    case imageViewer, pdfViewer, mediaPlayer, textEditor

    static let pinned: [AppKind] = [.browser, .remoteDesktop, .files, .notes, .settings]
    static let launcher: [AppKind] = [.browser, .remoteDesktop, .files, .notes, .calculator, .settings, .help]
    static let desktopIcons: [AppKind] = [.files, .browser, .remoteDesktop, .notes]

    var title: String {
        switch self {
        case .browser: return "인터넷"
        case .files: return "내 파일"
        case .notes: return "메모"
        case .calculator: return "계산기"
        case .remoteDesktop: return "원격 데스크톱"
        case .settings: return "설정"
        case .help: return "도움말"
        case .imageViewer: return "사진 보기"
        case .pdfViewer: return "PDF 보기"
        case .mediaPlayer: return "미디어 플레이어"
        case .textEditor: return "텍스트 편집기"
        }
    }

    var iconStyle: IconTileView.Style {
        switch self {
        case .browser: return .init(symbol: "globe", colors: [UIColor(hex: 0x58A6FF), UIColor(hex: 0x1F5FD6)])
        case .files: return .init(symbol: "folder.fill", colors: [UIColor(hex: 0xFFC34D), UIColor(hex: 0xF08C1A)])
        case .notes: return .init(symbol: "note.text", colors: [UIColor(hex: 0xFFE066), UIColor(hex: 0xF2B705)], foreground: UIColor(hex: 0x4A3B00))
        case .calculator: return .init(symbol: "plus.forwardslash.minus", colors: [UIColor(hex: 0x8A8D98), UIColor(hex: 0x4E515B)])
        case .remoteDesktop: return .init(symbol: "display", colors: [UIColor(hex: 0x30D5C8), UIColor(hex: 0x1F8F86)])
        case .settings: return .init(symbol: "gearshape.fill", colors: [UIColor(hex: 0x9A9AA1), UIColor(hex: 0x56565C)])
        case .help: return .init(symbol: "questionmark", colors: [UIColor(hex: 0x6CD4FF), UIColor(hex: 0x2D9CDB)])
        case .imageViewer: return .init(symbol: "photo.fill", colors: [UIColor(hex: 0x4CD964), UIColor(hex: 0x1E9E45)])
        case .pdfViewer: return .init(symbol: "doc.richtext.fill", colors: [UIColor(hex: 0xFF6259), UIColor(hex: 0xC9302C)])
        case .mediaPlayer: return .init(symbol: "play.fill", colors: [UIColor(hex: 0xC77DFF), UIColor(hex: 0x7D3AB5)])
        case .textEditor: return .init(symbol: "doc.plaintext.fill", colors: [UIColor(hex: 0x7FDBFF), UIColor(hex: 0x2FA8D8)])
        }
    }

    var isSingleInstance: Bool {
        self == .settings || self == .help || self == .calculator
    }

    func defaultSize(in area: CGSize) -> CGSize {
        let size: CGSize
        switch self {
        case .browser: size = CGSize(width: area.width * 0.68, height: area.height * 0.82)
        case .files: size = CGSize(width: Theme.s(820), height: Theme.s(540))
        case .notes, .textEditor: size = CGSize(width: Theme.s(780), height: Theme.s(560))
        case .calculator: size = CGSize(width: Theme.s(320), height: Theme.s(480))
        case .remoteDesktop: size = CGSize(width: area.width * 0.72, height: area.height * 0.84)
        case .settings: size = CGSize(width: Theme.s(720), height: Theme.s(620))
        case .help: size = CGSize(width: Theme.s(700), height: Theme.s(640))
        case .imageViewer, .pdfViewer: size = CGSize(width: area.width * 0.6, height: area.height * 0.8)
        case .mediaPlayer: size = CGSize(width: area.width * 0.6, height: area.width * 0.6 * 9 / 16 + Theme.s(90))
        }
        return CGSize(width: min(size.width, area.width - Theme.s(20)), height: min(size.height, area.height - Theme.s(20)))
    }

    func makeContent(url: URL?, fileURL: URL?, configuration: WKWebViewConfiguration?) -> AppContentView {
        switch self {
        case .browser: return BrowserContent(url: url ?? fileURL, configuration: configuration)
        case .files: return FilesContent(directory: fileURL ?? FileStore.documents)
        case .notes: return NotesContent()
        case .calculator: return CalculatorContent()
        case .remoteDesktop: return RemoteDesktopContent()
        case .settings: return SettingsContent()
        case .help: return HelpContent()
        case .imageViewer: return ImageViewerContent(fileURL: fileURL)
        case .pdfViewer: return PDFViewerContent(fileURL: fileURL)
        case .mediaPlayer: return MediaPlayerContent(fileURL: fileURL)
        case .textEditor: return TextFileContent(fileURL: fileURL)
        }
    }
}

enum ShortcutIcons {
    private static let palette: [[UIColor]] = [
        [UIColor(hex: 0x5E8BFF), UIColor(hex: 0x3A5BD9)],
        [UIColor(hex: 0xFF8A65), UIColor(hex: 0xE5533D)],
        [UIColor(hex: 0x4DD0A1), UIColor(hex: 0x1E9E7A)],
        [UIColor(hex: 0xBA8CFF), UIColor(hex: 0x7B4FD6)],
        [UIColor(hex: 0xFFC857), UIColor(hex: 0xE09B12)],
        [UIColor(hex: 0x5BC0EB), UIColor(hex: 0x2A86C2)],
    ]

    static func style(for shortcut: WebShortcut) -> IconTileView.Style {
        let host = URL(string: shortcut.url)?.host?.lowercased() ?? ""
        if host.contains("youtube") {
            return .init(symbol: "play.fill", colors: [UIColor(hex: 0xFF3B30), UIColor(hex: 0xC4161C)])
        }
        if host.contains("naver") {
            return .init(letter: "N", colors: [UIColor(hex: 0x19CE60), UIColor(hex: 0x03A94D)])
        }
        if host == "mail.google.com" || host.contains("gmail") {
            return .init(symbol: "envelope.fill", colors: [UIColor(hex: 0xEA4335), UIColor(hex: 0xB3261E)])
        }
        if host.hasPrefix("docs.google") {
            return .init(symbol: "doc.text.fill", colors: [UIColor(hex: 0x4285F4), UIColor(hex: 0x2A63C8)])
        }
        if host.contains("google") {
            return .init(letter: "G", colors: [UIColor.white, UIColor(hex: 0xE3E6EA)], foreground: UIColor(hex: 0x4285F4))
        }
        if host.contains("netflix") {
            return .init(letter: "N", colors: [UIColor(hex: 0x222222), UIColor.black], foreground: UIColor(hex: 0xE50914))
        }
        let seed = host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let letter = shortcut.title.first.map { String($0).uppercased() } ?? "?"
        return .init(letter: letter, colors: palette[seed % palette.count])
    }
}

/// Base class for an app's content inside a `DeskWindow`.
class AppContentView: UIView {
    weak var deskWindow: DeskWindow?
    var desktop: DesktopViewController? { DeskSession.shared.desktop }

    var title: String = "" {
        didSet { if title != oldValue { deskWindow?.titleDidChange() } }
    }

    /// Where keyboard input goes when the window becomes active.
    var preferredKeyTarget: KeyInputTarget? { nil }

    /// App-level shortcuts (⌘/Ctrl + key). Return true when handled.
    func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool { false }

    /// App-level special keys, checked before the focused target gets them.
    func interceptSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) -> Bool { false }

    func didActivate() {}
    func willClose() {}
    func exitFullscreen() {}

    /// Extra items for the window's title-bar menu.
    func windowMenuItems() -> [MenuItem] { [] }
}
