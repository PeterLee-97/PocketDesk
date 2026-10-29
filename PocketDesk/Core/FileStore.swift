import UIKit
import UniformTypeIdentifiers

enum FileKind {
    case folder, image, pdf, video, audio, text, web, document, archive, other

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .text: return "doc.plaintext.fill"
        case .web: return "globe"
        case .document: return "doc.fill"
        case .archive: return "archivebox.fill"
        case .other: return "doc"
        }
    }

    var tint: UIColor {
        switch self {
        case .folder: return UIColor(hex: 0xF5A623)
        case .image: return UIColor(hex: 0x34C759)
        case .pdf: return UIColor(hex: 0xFF453A)
        case .video: return UIColor(hex: 0xAF52DE)
        case .audio: return UIColor(hex: 0xFF375F)
        case .text: return UIColor(hex: 0x64D2FF)
        case .web: return UIColor(hex: 0x4A8FFF)
        case .document: return UIColor(hex: 0x5E8BFF)
        case .archive: return UIColor(hex: 0xA2845E)
        case .other: return UIColor(hex: 0x8E8E93)
        }
    }
}

/// The app's sandboxed "disk". Visible in the iOS Files app under "On My iPhone › PocketDesk".
enum FileStore {
    struct Item {
        let url: URL
        let name: String
        let kind: FileKind
        let size: Int64
        let modified: Date?
    }

    /// Posted after the app itself adds, renames or removes files.
    static let didChange = Notification.Name("PocketDeskFilesDidChange")

    static func notifyChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static var downloads: URL { documents.appendingPathComponent("다운로드", isDirectory: true) }
    static var notes: URL { documents.appendingPathComponent("메모", isDirectory: true) }
    static var imports: URL { documents.appendingPathComponent("가져온 파일", isDirectory: true) }
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var wallpaperFile: URL { support.appendingPathComponent("wallpaper.jpg") }

    static func prepareDirectories() {
        for directory in [downloads, notes, imports, support] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let name = preferredName.isEmpty ? "이름 없음" : preferredName
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func kind(of url: URL) -> FileKind {
        if isDirectory(url) { return .folder }
        let ext = url.pathExtension.lowercased()
        if ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "rtfd"].contains(ext) {
            return .document
        }
        if ["md", "markdown", "json", "csv", "tsv", "log", "yml", "yaml", "xml", "ini", "conf", "srt", "smi"].contains(ext) {
            return .text
        }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .html) { return .web }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
        if type.conforms(to: .archive) { return .archive }
        return .other
    }

    static func contents(of directory: URL) -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        let items = urls.map { url -> Item in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let kind: FileKind = values?.isDirectory == true ? .folder : FileStore.kind(of: url)
            return Item(
                url: url, name: url.lastPathComponent, kind: kind,
                size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate
            )
        }
        return items.sorted { a, b in
            if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func displayName(of directory: URL) -> String {
        directory.standardizedFileURL.path == documents.standardizedFileURL.path ? "내 파일" : directory.lastPathComponent
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy. M. d. a h:mm"
        return formatter
    }()

    /// Reads text, falling back to EUC-KR for older Korean files.
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        let eucKR = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: eucKR)) { return text }
        return String(data: data, encoding: .utf16)
    }
}
