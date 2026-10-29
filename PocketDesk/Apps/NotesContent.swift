import UIKit

/// Notes stored as .txt files in "내 파일 › 메모", with a list on the left.
final class NotesContent: AppContentView {
    private let sidebar = UIView()
    private let newButton = DeskButton(symbol: "square.and.pencil", title: "새 메모")
    private let list = DeskListView()
    private let divider = UIView()
    private let editor = TextEditorView()
    private var notes: [URL] = []
    private var currentURL: URL?
    private var saveTimer: Timer?
    private var isDirty = false

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.windowBackground
        sidebar.backgroundColor = Theme.panel
        addSubview(sidebar)
        newButton.alignment = .leading
        newButton.normalBackground = UIColor(white: 1, alpha: 0.07)
        newButton.onTap = { [weak self] in self?.createNote() }
        sidebar.addSubview(newButton)
        list.rowHeight = 48
        list.showsDetail = false
        list.emptyText = "메모가 없습니다"
        list.onSelect = { [weak self] index in self?.openNote(at: index) }
        list.onContextMenu = { [weak self] index, event in self?.showNoteMenu(for: index, at: event.location) }
        sidebar.addSubview(list)
        divider.backgroundColor = Theme.separator
        addSubview(divider)
        editor.placeholder = "여기에 메모를 입력하세요"
        editor.inputDescription = "메모"
        editor.onChange = { [weak self] in self?.scheduleSave() }
        addSubview(editor)
        title = "메모"
        reload()
        if notes.isEmpty {
            createNote()
        } else {
            openNote(at: 0)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(filesChanged), name: FileStore.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? { editor }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sidebarWidth = min(Theme.s(240), bounds.width * 0.38)
        sidebar.frame = CGRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        newButton.frame = CGRect(x: Theme.s(10), y: Theme.s(10), width: sidebarWidth - Theme.s(20), height: Theme.s(34))
        list.frame = CGRect(x: 0, y: newButton.frame.maxY + Theme.s(8), width: sidebarWidth, height: max(0, bounds.height - newButton.frame.maxY - Theme.s(8)))
        divider.frame = CGRect(x: sidebarWidth, y: 0, width: 1, height: bounds.height)
        editor.frame = CGRect(x: sidebarWidth + 1, y: 0, width: max(0, bounds.width - sidebarWidth - 1), height: bounds.height)
    }

    // MARK: Storage

    private static func title(of text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? "새 메모" : String(firstLine.prefix(40))
    }

    private func reload() {
        let items = FileStore.contents(of: FileStore.notes)
            .filter { $0.kind == .text }
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        notes = items.map { $0.url }
        list.items = items.map { item in
            let text = item.url.lastPathComponent == currentURL?.lastPathComponent ? editor.text : (FileStore.readText(item.url) ?? "")
            return DeskListItem(
                title: NotesContent.title(of: text),
                subtitle: item.modified.map { FileStore.dateFormatter.string(from: $0) },
                detail: nil, symbol: "note.text", tint: UIColor(hex: 0xF2C94C)
            )
        }
        list.selectedIndex = notes.firstIndex { $0.lastPathComponent == currentURL?.lastPathComponent }
    }

    private func createNote() {
        saveNow()
        let name = "메모 \(NotesContent.fileNameFormatter.string(from: Date())).txt"
        let url = FileStore.uniqueURL(in: FileStore.notes, preferredName: name)
        try? "".write(to: url, atomically: true, encoding: .utf8)
        currentURL = url
        editor.setText("")
        title = "메모"
        reload()
        if deskWindow?.isActive == true { desktop?.setKeyFocus(editor) }
    }

    private func openNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        let url = notes[index]
        guard url.lastPathComponent != currentURL?.lastPathComponent else { return }
        saveNow()
        currentURL = url
        let text = FileStore.readText(url) ?? ""
        editor.setText(text)
        title = "메모 — \(NotesContent.title(of: text))"
        if deskWindow?.isActive == true { desktop?.setKeyFocus(editor) }
    }

    private func scheduleSave() {
        isDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(timeInterval: 0.8, target: self, selector: #selector(saveTimerFired), userInfo: nil, repeats: false)
    }

    @objc private func saveTimerFired() {
        saveNow()
        title = "메모 — \(NotesContent.title(of: editor.text))"
        reload()
    }

    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isDirty, let url = currentURL else { return }
        isDirty = false
        try? editor.text.write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func filesChanged() {
        reload()
    }

    private func deleteNote(at index: Int) {
        guard notes.indices.contains(index) else { return }
        let url = notes[index]
        desktop?.confirm(title: "이 메모를 삭제할까요?", message: "삭제한 메모는 되돌릴 수 없습니다.", confirmTitle: "삭제", destructive: true) { [weak self] confirmed in
            guard confirmed, let self else { return }
            let wasCurrent = url.lastPathComponent == self.currentURL?.lastPathComponent
            if wasCurrent {
                self.saveTimer?.invalidate()
                self.isDirty = false
                self.currentURL = nil
            }
            try? FileManager.default.removeItem(at: url)
            self.reload()
            if wasCurrent {
                if self.notes.isEmpty { self.createNote() } else { self.openNote(at: 0) }
            }
            FileStore.notifyChange()
        }
    }

    private func showNoteMenu(for index: Int?, at point: CGPoint) {
        var items = [MenuItem(title: "새 메모", symbol: "square.and.pencil", shortcut: "⌘N") { [weak self] in self?.createNote() }]
        if let index {
            items.append(.separator)
            items.append(MenuItem(title: "삭제", symbol: "trash", isDestructive: true) { [weak self] in self?.deleteNote(at: index) })
        }
        desktop?.showContextMenu(items, at: point)
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey else { return false }
        switch key {
        case "n":
            createNote()
            return true
        case "s":
            isDirty = true
            saveNow()
            desktop?.showToast("메모를 저장했습니다", symbol: "checkmark.circle")
            return true
        default:
            return false
        }
    }

    override func willClose() {
        saveNow()
        NotificationCenter.default.removeObserver(self)
        // Don't leave blank notes behind.
        if let url = currentURL, editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: url)
            FileStore.notifyChange()
        }
    }
}

/// Plain-text editor for a single file opened from the file manager.
final class TextFileContent: AppContentView {
    private let toolbar = UIView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let saveButton = DeskButton(symbol: "square.and.arrow.down", title: "저장")
    private let editor = TextEditorView()
    private let fileURL: URL?
    private var saveTimer: Timer?
    private var isDirty = false { didSet { updateStatus() } }

    private static let codeExtensions: Set<String> = [
        "json", "swift", "js", "ts", "py", "xml", "yml", "yaml", "csv", "tsv", "log", "c", "h", "m", "cpp",
        "java", "kt", "sh", "css", "html", "md", "ini", "conf", "sql",
    ]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        super.init(frame: .zero)
        backgroundColor = Theme.windowBackground
        toolbar.backgroundColor = Theme.panel
        addSubview(toolbar)
        nameLabel.textColor = Theme.text
        nameLabel.text = fileURL?.lastPathComponent ?? "제목 없음"
        nameLabel.lineBreakMode = .byTruncatingMiddle
        toolbar.addSubview(nameLabel)
        statusLabel.textColor = Theme.secondaryText
        toolbar.addSubview(statusLabel)
        saveButton.normalBackground = UIColor(white: 1, alpha: 0.08)
        saveButton.onTap = { [weak self] in self?.save(showToast: true) }
        toolbar.addSubview(saveButton)
        editor.isMonospaced = TextFileContent.codeExtensions.contains(fileURL?.pathExtension.lowercased() ?? "")
        editor.fontSize = editor.isMonospaced ? 13.5 : 15
        editor.inputDescription = "텍스트 편집기"
        if let fileURL, let text = FileStore.readText(fileURL) {
            editor.setText(text)
        } else if fileURL != nil {
            editor.setText("이 파일은 텍스트로 열 수 없습니다.")
            editor.isEditable = false
            saveButton.isEnabled = false
        }
        editor.onChange = { [weak self] in
            self?.isDirty = true
            self?.scheduleSave()
        }
        addSubview(editor)
        title = fileURL?.lastPathComponent ?? "텍스트 편집기"
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredKeyTarget: KeyInputTarget? { editor }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barHeight = Theme.s(40)
        toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        nameLabel.font = Theme.font(13, .medium)
        statusLabel.font = Theme.font(12)
        let buttonWidth = saveButton.preferredWidth()
        saveButton.frame = CGRect(x: bounds.width - buttonWidth - Theme.s(10), y: Theme.s(5), width: buttonWidth, height: barHeight - Theme.s(10))
        let statusWidth = Theme.s(150)
        statusLabel.frame = CGRect(x: saveButton.frame.minX - statusWidth - Theme.s(10), y: 0, width: statusWidth, height: barHeight)
        statusLabel.textAlignment = .right
        nameLabel.frame = CGRect(x: Theme.s(14), y: 0, width: max(0, statusLabel.frame.minX - Theme.s(24)), height: barHeight)
        editor.frame = CGRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))
    }

    private func updateStatus() {
        if !editor.isEditable {
            statusLabel.text = "읽기 전용"
        } else {
            statusLabel.text = isDirty ? "편집됨" : "저장됨 (UTF-8)"
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(autosave), userInfo: nil, repeats: false)
    }

    @objc private func autosave() {
        save(showToast: false)
    }

    private func save(showToast: Bool) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let fileURL, editor.isEditable else { return }
        do {
            try editor.text.write(to: fileURL, atomically: true, encoding: .utf8)
            isDirty = false
            FileStore.notifyChange()
            if showToast { desktop?.showToast("저장했습니다: \(fileURL.lastPathComponent)", symbol: "checkmark.circle") }
        } catch {
            desktop?.showToast("저장하지 못했습니다: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    override func handleShortcut(_ key: String, modifiers: KeyModifiers) -> Bool {
        guard modifiers.hasShortcutKey, key == "s" else { return false }
        save(showToast: true)
        return true
    }

    override func willClose() {
        if isDirty { save(showToast: false) }
        saveTimer?.invalidate()
    }
}
