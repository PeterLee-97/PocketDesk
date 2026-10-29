import UIKit
import UniformTypeIdentifiers

/// File manager for the app's Documents folder (also visible in the iOS Files app).
final class FilesContent: AppContentView, KeyInputTarget, UIDocumentPickerDelegate {
    private let toolbar = UIView()
    private let backButton = DeskButton(symbol: "chevron.left")
    private let upButton = DeskButton(symbol: "arrow.up")
    private let pathLabel = UILabel()
    private let newFolderButton = DeskButton(symbol: "folder.badge.plus")
    private let importButton = DeskButton(symbol: "iphone.and.arrow.forward", title: "iPhone에서 가져오기")
    private let sidebar = UIView()
    private var placeButtons: [(URL, DeskButton)] = []
    private let list = DeskListView()
    private let statusLabel = UILabel()

    private(set) var directory: URL
    private var history: [URL] = []
    private var items: [FileStore.Item] = []
    private var typeAhead = ""
    private var typeAheadTime: CFTimeInterval = 0

    init(directory: URL) {
        self.directory = directory
        super.init(frame: .zero)
        backgroundColor = Theme.windowBackground
        toolbar.backgroundColor = Theme.panel
        addSubview(toolbar)
        for button in [backButton, upButton, newFolderButton] {
            button.symbolSize = 14
            toolbar.addSubview(button)
        }
        importButton.normalBackground = Theme.accent.withAlphaComponent(0.9)
        importButton.hoverBackground = Theme.accent
        importButton.tint = .white
        importButton.fontSize = 12.5
        toolbar.addSubview(importButton)
        pathLabel.textColor = Theme.text
        pathLabel.lineBreakMode = .byTruncatingHead
        toolbar.addSubview(pathLabel)
        backButton.onTap = { [weak self] in self?.goBack() }
        upButton.onTap = { [weak self] in self?.goUp() }
        newFolderButton.onTap = { [weak self] in self?.promptNewFolder() }
        importButton.onTap = { [weak self] in self?.importFromPhone() }

        sidebar.backgroundColor = UIColor(hex: 0x202125)
        addSubview(sidebar)
        let places: [(URL, String, String)] = [
            (FileStore.documents, "내 파일", "house"),
            (FileStore.downloads, "다운로드", "arrow.down.circle"),
            (FileStore.notes, "메모", "note.text"),
            (FileStore.imports, "가져온 파일", "square.and.arrow.down"),
        ]
        for (url, name, symbol) in places {
            let button = DeskButton(symbol: symbol, title: name)
            button.alignment = .leading
            button.fontSize = 13
            button.toggledBackground = Theme.selection
            button.onTap = { [weak self] in self?.navigate(to: url) }
            placeButtons.append((url, button))
            sidebar.addSubview(button)
        }

        list.rowHeight = 34
        list.emptyText = "이 폴더는 비어 있습니다.\niPhone에서 가져오기를 누르거나 iOS '파일' 앱의 'PocketDesk' 폴더에 파일을 넣으세요."
        list.onActivate = { [weak self] index in self?.activate(index) }
        list.activatesOnSingleClick = true
        list.onSelect = { [weak self] _ in self?.updateStatus() }
        list.onContextMenu = { [weak self] index, event in self?.showMenu(for: index, at: event.location) }
        addSubview(list)
        statusLabel.textColor = Theme.secondaryText
        addSubview(statusLabel)

        NotificationCenter.default.addObserver(self, selector: #selector(filesChanged), name: FileStore.didChange, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? { self }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barHeight = Theme.s(44)
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let size = Theme.s(30)
        let y = (barHeight - size) / 2
        backButton.frame = CGRect(x: Theme.s(8), y: y, width: size, height: size)
        upButton.frame = CGRect(x: backButton.frame.maxX + Theme.s(2), y: y, width: size, height: size)
        let importWidth = importButton.preferredWidth()
        importButton.frame = CGRect(x: bounds.width - importWidth - Theme.s(10), y: y, width: importWidth, height: size)
        newFolderButton.frame = CGRect(x: importButton.frame.minX - size - Theme.s(6), y: y, width: size, height: size)
        pathLabel.font = Theme.font(13, .medium)
        pathLabel.frame = CGRect(x: upButton.frame.maxX + Theme.s(12), y: 0, width: max(0, newFolderButton.frame.minX - upButton.frame.maxX - Theme.s(20)), height: barHeight)

        let sidebarWidth = min(Theme.s(180), bounds.width * 0.3)
        let statusHeight = Theme.s(26)
        sidebar.frame = CGRect(x: 0, y: barHeight, width: sidebarWidth, height: bounds.height - barHeight)
        var placeY = Theme.s(10)
        for (_, button) in placeButtons {
            button.frame = CGRect(x: Theme.s(8), y: placeY, width: sidebarWidth - Theme.s(16), height: Theme.s(32))
            placeY += Theme.s(34)
        }
        list.frame = CGRect(x: sidebarWidth, y: barHeight, width: bounds.width - sidebarWidth, height: max(0, bounds.height - barHeight - statusHeight))
        statusLabel.font = Theme.font(11.5)
        statusLabel.frame = CGRect(x: sidebarWidth + Theme.s(12), y: bounds.height - statusHeight, width: bounds.width - sidebarWidth - Theme.s(24), height: statusHeight)
    }

    // MARK: Navigation

    private func reload() {
        let selectedName = list.selectedIndex.flatMap { items.indices.contains($0) ? items[$0].name : nil }
        items = FileStore.contents(of: directory)
        list.items = items.map { item in
            var detail = item.modified.map { FileStore.dateFormatter.string(from: $0) } ?? ""
            if item.kind != .folder { detail += "  ·  " + FileStore.formattedSize(item.size) }
            return DeskListItem(title: item.name, subtitle: nil, detail: detail, symbol: item.kind.symbol, tint: item.kind.tint)
        }
        list.selectedIndex = selectedName.flatMap { name in items.firstIndex { $0.name == name } }
        let name = FileStore.displayName(of: directory)
        title = name
        pathLabel.text = relativePath()
        backButton.isEnabled = !history.isEmpty
        upButton.isEnabled = !isRoot
        for (url, button) in placeButtons {
            button.isToggled = url.standardizedFileURL.path == directory.standardizedFileURL.path
        }
        updateStatus()
    }

    private var isRoot: Bool {
        directory.standardizedFileURL.path == FileStore.documents.standardizedFileURL.path
    }

    private func relativePath() -> String {
        let root = FileStore.documents.standardizedFileURL.path
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix(root) else { return directory.lastPathComponent }
        let rest = path.dropFirst(root.count).split(separator: "/").joined(separator: " › ")
        return rest.isEmpty ? "내 파일" : "내 파일 › " + rest
    }

    private func updateStatus() {
        let folders = items.filter { $0.kind == .folder }.count
        var text = "항목 \(items.count)개"
        if folders > 0 { text += " (폴더 \(folders)개)" }
        if let index = list.selectedIndex, items.indices.contains(index) {
            let item = items[index]
            text += "  ·  선택: \(item.name)"
            if item.kind != .folder { text += " (\(FileStore.formattedSize(item.size)))" }
        }
        statusLabel.text = text
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        guard url.standardizedFileURL.path != directory.standardizedFileURL.path else { return }
        if recordHistory { history.append(directory) }
        directory = url
        list.selectedIndex = nil
        list.contentOffset = .zero
        reload()
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        navigate(to: previous, recordHistory: false)
    }

    private func goUp() {
        guard !isRoot else { return }
        navigate(to: directory.deletingLastPathComponent())
    }

    private func activate(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if item.kind == .folder {
            navigate(to: item.url)
        } else {
            desktop?.openFile(item.url)
        }
    }

    @objc private func filesChanged() {
        reload()
    }

    override func didActivate() {
        reload()
    }

    // MARK: File operations

    private func promptNewFolder() {
        desktop?.prompt(title: "새 폴더", message: nil, text: "새 폴더", confirmTitle: "만들기") { [weak self] name in
            guard let self, let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            let url = FileStore.uniqueURL(in: self.directory, preferredName: name.replacingOccurrences(of: "/", with: "-"))
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                FileStore.notifyChange()
            } catch {
                self.desktop?.showToast("폴더를 만들 수 없습니다: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func rename(_ item: FileStore.Item) {
        desktop?.prompt(title: "이름 바꾸기", message: nil, text: item.name, confirmTitle: "변경") { [weak self] name in
            guard let self, let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != item.name else { return }
            let destination = item.url.deletingLastPathComponent().appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
            do {
                try FileManager.default.moveItem(at: item.url, to: destination)
                FileStore.notifyChange()
            } catch {
                self.desktop?.showToast("이름을 바꿀 수 없습니다: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func delete(_ item: FileStore.Item) {
        let what = item.kind == .folder ? "폴더와 그 안의 모든 항목이" : "파일이"
        desktop?.confirm(title: "'\(item.name)'을(를) 삭제할까요?", message: "\(what) 영구적으로 삭제됩니다.", confirmTitle: "삭제", destructive: true) { [weak self] confirmed in
            guard confirmed else { return }
            do {
                try FileManager.default.removeItem(at: item.url)
                FileStore.notifyChange()
            } catch {
                self?.desktop?.showToast("삭제할 수 없습니다: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    private func share(_ item: FileStore.Item) {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        DeskSession.shared.presentOnPhone(controller)
        desktop?.showToast("iPhone 화면에서 공유할 방법을 선택하세요", symbol: "iphone")
    }

    private func importFromPhone() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        DeskSession.shared.presentOnPhone(picker)
        desktop?.showToast("iPhone 화면에서 가져올 파일을 선택하세요", symbol: "iphone")
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var imported = 0
        for url in urls {
            let destination = FileStore.uniqueURL(in: directory, preferredName: url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                imported += 1
            } catch {
                if (try? FileManager.default.copyItem(at: url, to: destination)) != nil { imported += 1 }
            }
        }
        FileStore.notifyChange()
        desktop?.showToast("파일 \(imported)개를 가져왔습니다", symbol: "checkmark.circle")
    }

    private func showMenu(for index: Int?, at point: CGPoint) {
        var menu: [MenuItem] = []
        if let index, items.indices.contains(index) {
            let item = items[index]
            menu += [
                MenuItem(title: "열기", symbol: "arrow.up.forward.app") { [weak self] in self?.activate(index) },
                MenuItem(title: "이름 바꾸기…", symbol: "pencil") { [weak self] in self?.rename(item) },
            ]
            if item.kind != .folder {
                menu.append(MenuItem(title: "iPhone에서 공유…", symbol: "square.and.arrow.up") { [weak self] in self?.share(item) })
            }
            menu += [
                .separator,
                MenuItem(title: "삭제", symbol: "trash", isDestructive: true) { [weak self] in self?.delete(item) },
            ]
        } else {
            menu += [
                MenuItem(title: "새 폴더", symbol: "folder.badge.plus") { [weak self] in self?.promptNewFolder() },
                MenuItem(title: "iPhone에서 가져오기…", symbol: "iphone.and.arrow.forward") { [weak self] in self?.importFromPhone() },
                MenuItem(title: "새로 고침", symbol: "arrow.clockwise") { [weak self] in self?.reload() },
            ]
        }
        desktop?.showContextMenu(menu, at: point)
    }

    // MARK: Keyboard

    var acceptsTextInput: Bool { false }
    var inputDescription: String { "파일 목록" }

    func insertText(_ text: String) {
        // Type-ahead: jump to the first item starting with the typed letters.
        let now = CACurrentMediaTime()
        typeAhead = now - typeAheadTime > 1 ? text : typeAhead + text
        typeAheadTime = now
        let needle = typeAhead.lowercased()
        if let index = items.firstIndex(where: { $0.name.lowercased().hasPrefix(needle) }) {
            list.selectedIndex = index
            list.scrollToRow(index)
            updateStatus()
        }
    }

    func deleteBackward() {
        goBack()
    }

    func handleSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers) {
        switch key {
        case .up:
            if modifiers.hasShortcutKey { goUp() } else { list.moveSelection(by: -1) }
        case .down:
            if modifiers.hasShortcutKey, let index = list.selectedIndex { activate(index) } else { list.moveSelection(by: 1) }
        case .enter:
            if let index = list.selectedIndex { activate(index) }
        case .deleteForward:
            if let index = list.selectedIndex, items.indices.contains(index) { delete(items[index]) }
        case .home:
            list.moveSelection(by: -items.count)
        case .end:
            list.moveSelection(by: items.count)
        case .pageUp:
            list.moveSelection(by: -10)
        case .pageDown:
            list.moveSelection(by: 10)
        default:
            break
        }
        updateStatus()
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        if key == "n" && modifiers.contains(.shift) {
            promptNewFolder()
            return true
        }
        if key == "[" {
            goBack()
            return true
        }
        return false
    }

    override func willClose() {
        NotificationCenter.default.removeObserver(self)
    }
}
