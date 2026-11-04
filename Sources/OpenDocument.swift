import AppKit

/// One tab: a Markdown file (or Untitled) with its own editor. Bytes go through `MarkdownDocument`
/// only (BOM, CRLF, "not UTF-8"), so an untouched file is written back byte for byte.
@MainActor
final class OpenDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var url: URL?
    /// Text differs from the text that matches `diskData` (undoing back to it makes the tab clean).
    @Published private(set) var isDirty = false
    /// File name, or "Untitled 2".
    @Published private(set) var displayName: String
    private(set) var file: MarkdownDocument
    /// Bytes last read from or written to disk; nil for Untitled. A save compares the disk with these.
    private(set) var diskData: Data?
    /// Text that matches `diskData`.
    private(set) var savedText: String
    /// Created on first show (TB-16).
    private(set) var controller: EditorController?
    /// The user declined to overwrite a foreign change during autosave, or the file changed on disk while
    /// the tab had edits: no autosave until an explicit save (or a reload).
    private(set) var autosavePaused = false
    /// Changed on disk while dirty and not answered yet: the tab asks when it is shown (ARCH 2.6).
    private(set) var pendingConflict = false
    /// Foreign bytes the user already answered about (overwrite question, conflict sheet): not asked again.
    private var answeredDiskData: Data?
    let watcher = FileWatcher()
    /// Debounce after the last edit; tests set it lower.
    static var autosaveDelay: Duration = .seconds(2)
    /// Runs when the debounce ends (TabStore saves the tab: prompter, Open Recent).
    var onAutosave: (@MainActor (OpenDocument) async -> Void)?
    /// The file changed on disk while the tab had edits (TabStore asks now or when the tab is shown).
    var onConflict: (@MainActor (OpenDocument) -> Void)?
    private var autosaveTask: Task<Void, Never>?

    init(untitledName: String) {
        displayName = untitledName
        file = MarkdownDocument()
        savedText = ""
    }

    /// Throws `MarkdownDocumentError.notUTF8` for non-UTF-8 files, file system errors otherwise.
    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        file = try MarkdownDocument(data: data)
        self.url = url
        displayName = url.lastPathComponent
        diskData = data
        savedText = file.text
        startWatching()
    }

    private func startWatching() {
        watcher.knownData = { [weak self] in self?.diskData }
        watcher.isDirty = { [weak self] in self?.isDirty ?? false }
        watcher.reload = { [weak self] data in
            guard let self else { return }
            do { try self.reload(from: data) } catch {
                log.error("reload failed, keeping the text: \(self.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        watcher.conflict = { [weak self] data in self?.changedOnDiskWhileDirty(data) }
        watcher.watch(url)
    }

    var text: String { file.text }
    func data() -> Data { file.data() }

    func makeController(mode: EditorMode, zoom: Double) -> EditorController {
        if let controller { return controller }
        let made = EditorController(text: text, mode: mode, documentDirectory: url?.deletingLastPathComponent())
        made.setZoom(zoom)
        made.onTextChange = { [weak self] in self?.editorChanged($0) }
        controller = made
        return made
    }

    /// From `controller.onTextChange`.
    func editorChanged(_ text: String) {
        file.text = text
        isDirty = text != savedText
        scheduleAutosave()
    }

    /// Writes the tab to its file if it is dirty (or `force`, used by the byte test only).
    /// Checks the disk first and asks before overwriting a change made by another app.
    /// Untitled: false (the caller runs Save As).
    func save(prompter: SavePrompting, reason: SaveReason = .explicit, force: Bool = false) async -> Bool {
        guard let url else { return false }
        guard isDirty || force else { return true }
        if reason == .autosave, autosavePaused { return false }
        let diskNow = try? Data(contentsOf: url)
        if diskNow != diskData {
            answeredDiskData = diskNow
            pendingConflict = false // this question answers the conflict too
            guard await prompter.askOverwrite(self) == .overwrite else {
                if reason == .autosave { autosavePaused = true }
                log.info("save cancelled: \(url.path, privacy: .public) changed on disk")
                return false
            }
        }
        return await write(to: url, prompter: prompter)
    }

    /// Writes to `target` and makes it the tab's file. The save panel already asked about replacing it.
    func saveAs(_ target: URL, prompter: SavePrompting) async -> Bool {
        guard await write(to: target, prompter: prompter) else { return false }
        url = target
        displayName = target.lastPathComponent
        controller?.setDocumentDirectory(target.deletingLastPathComponent())
        startWatching() // the new file (Untitled had no watcher yet)
        return true
    }

    /// Takes the disk version: a clean tab changed by another app, or "Reload from Disk".
    /// Not UTF-8: throws, the tab keeps its text.
    func reload(from data: Data) throws {
        let fresh = try MarkdownDocument(data: data)
        autosaveTask?.cancel()
        autosaveTask = nil
        file = fresh
        diskData = data
        savedText = fresh.text
        isDirty = false
        autosavePaused = false
        pendingConflict = false
        controller?.load(text: fresh.text)
    }

    /// FileWatcher: another app changed the file while the tab has edits. No autosave until the user answers.
    private func changedOnDiskWhileDirty(_ data: Data) {
        guard data != answeredDiskData else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        autosavePaused = true
        pendingConflict = true
        onConflict?(self)
    }

    /// The conflict sheet was answered. Keep: autosave stays paused, the next save asks before overwriting.
    func conflictAnswered(reload: Bool) {
        pendingConflict = false
        guard let url, let disk = try? Data(contentsOf: url) else { return }
        answeredDiskData = disk
        guard reload else { return }
        do { try self.reload(from: disk) } catch {
            log.error("reload failed, keeping the text: \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The tab is going away: no more autosaves, the web view is released.
    func close() {
        autosaveTask?.cancel()
        autosaveTask = nil
        watcher.watch(nil)
        controller = nil
    }

    private func write(to target: URL, prompter: SavePrompting) async -> Bool {
        let text = file.text
        let bytes = file.data()
        do {
            try Self.replaceFile(at: target.resolvingSymlinksInPath(), with: bytes)
        } catch {
            log.error("save failed: \(target.path, privacy: .public): \(String(describing: error), privacy: .public)")
            await prompter.report(error, for: self)
            return false
        }
        log.info("saved \(target.path, privacy: .public) (\(bytes.count) bytes)")
        diskData = bytes
        savedText = text
        isDirty = file.text != savedText
        autosavePaused = false
        pendingConflict = false
        return true
    }

    /// Writes a temporary file next to the target and swaps it in with `replaceItemAt`, which keeps the
    /// original's permissions and creation date (`Data.write(options: .atomic)` does not).
    static func replaceFile(at target: URL, with bytes: Data) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: target.path)
        // A new file (Save As) has no item yet: its folder is on the same volume.
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                             appropriateFor: exists ? target : target.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: dir) }
        let tmp = dir.appending(path: target.lastPathComponent)
        try bytes.write(to: tmp)
        if exists {
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: target)
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty, url != nil, !autosavePaused else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.autosaveTask = nil
            await self.onAutosave?(self)
        }
    }
}
