import AppKit

/// The tabs of the main window. No UI here: the window and the tab bar observe it.
@MainActor
final class TabStore: ObservableObject {
    /// Creation order. ZStack order: never reordered, so moving a tab never re-parents a WKWebView.
    @Published private(set) var documents: [OpenDocument] = []
    /// Tab bar order.
    @Published private(set) var order: [OpenDocument.ID] = []
    @Published private(set) var activeID: OpenDocument.ID?
    /// Tabs that were shown at least once (they have a web view).
    @Published private(set) var shown: Set<OpenDocument.ID> = []
    let prompter: SavePrompting
    /// Tests: false, so the Open Recent menu of the installed app (same bundle id) stays clean.
    var recordsRecents = true
    /// Tabs whose conflict sheet is on screen (one sheet per tab).
    private var askingConflict: Set<OpenDocument.ID> = []

    init(prompter: SavePrompting) {
        self.prompter = prompter
    }

    /// In tab bar order.
    var tabs: [OpenDocument] { order.compactMap(document) }
    var active: OpenDocument? { activeID.flatMap(document) }

    func document(_ id: OpenDocument.ID) -> OpenDocument? {
        documents.first { $0.id == id }
    }

    // MARK: Opening

    /// Opens `url` in a new tab, or activates the tab that already has this file.
    /// Throws `MarkdownDocumentError.notUTF8` (no tab is added).
    /// `activate: false` (several files at once): the caller activates one tab at the end, so the
    /// other tabs get no web view until they are shown (TB-16).
    @discardableResult
    func open(_ url: URL, activate: Bool = true) throws -> OpenDocument {
        if let existing = tab(for: url) {
            if activate { self.activate(existing.id) }
            return existing
        }
        let doc = try OpenDocument(contentsOf: url)
        log.info("tab opened: \(url.path, privacy: .public)")
        add(doc, activate: activate)
        noteRecent(url)
        return doc
    }

    @discardableResult
    func newUntitled() -> OpenDocument {
        let taken = Set(documents.filter { $0.url == nil }.map(\.displayName))
        var name = "Untitled"
        var n = 2
        while taken.contains(name) {
            name = "Untitled \(n)"
            n += 1
        }
        let doc = OpenDocument(untitledName: name)
        add(doc)
        return doc
    }

    /// Same file: equal after `standardizedFileURL.resolvingSymlinksInPath()`, else the same
    /// `fileResourceIdentifier` (hard links, other letter case on a case-insensitive volume).
    func tab(for url: URL) -> OpenDocument? {
        let path = Self.canonical(url)
        if let doc = documents.first(where: { $0.url.map(Self.canonical) == path }) { return doc }
        guard let resource = Self.resourceID(url) else { return nil }
        return documents.first { doc in doc.url.flatMap(Self.resourceID)?.isEqual(resource) ?? false }
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func resourceID(_ url: URL) -> (any NSObjectProtocol)? {
        // A fresh URL: resource values are cached per URL object.
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }

    private func add(_ doc: OpenDocument, activate: Bool = true) {
        doc.onAutosave = { [weak self] doc in
            _ = await self?.save(doc, reason: .autosave)
        }
        // A hidden tab asks when it is shown (`activate`).
        doc.onConflict = { [weak self] doc in
            guard let self, doc.id == self.activeID else { return }
            Task { await self.resolveConflict(doc) }
        }
        documents.append(doc)
        order.append(doc.id)
        if activate { self.activate(doc.id) }
    }

    // MARK: Switching

    /// Shows the tab; a conflict that came while it was hidden is asked now (ARCH 2.6).
    func activate(_ id: OpenDocument.ID) {
        guard let doc = document(id) else { return }
        select(id)
        if doc.pendingConflict { Task { await resolveConflict(doc) } }
    }

    private func select(_ id: OpenDocument.ID) {
        activeID = id
        shown.insert(id)
    }

    /// The file changed on disk while the tab had edits: Keep My Version / Reload from Disk.
    func resolveConflict(_ doc: OpenDocument) async {
        guard doc.pendingConflict, !askingConflict.contains(doc.id) else { return }
        askingConflict.insert(doc.id)
        defer { askingConflict.remove(doc.id) }
        let response = await prompter.showConflict(doc)
        doc.conflictAnswered(reload: response == FileWatcher.reloadResponse)
    }

    /// Wraps around (TB-8).
    func activateNext() { step(1) }
    func activatePrevious() { step(-1) }

    private func step(_ delta: Int) {
        guard let activeID, let i = order.firstIndex(of: activeID) else { return }
        activate(order[(i + delta + order.count) % order.count])
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { order[$0] }
        var rest = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: destination - source.count(in: 0..<destination))
        order = rest
    }

    // MARK: Saving

    /// ⌘S, autosave, close, quit. Untitled: Save As panel (never for autosave).
    @discardableResult
    func save(_ doc: OpenDocument, reason: SaveReason = .explicit) async -> Bool {
        guard doc.url != nil else {
            guard reason != .autosave, let target = await prompter.chooseSaveURL(for: doc) else { return false }
            return await saveAs(doc, to: target)
        }
        guard await doc.save(prompter: prompter, reason: reason) else { return false }
        if let url = doc.url { noteRecent(url) }
        return true
    }

    @discardableResult
    func saveAs(_ doc: OpenDocument, to target: URL) async -> Bool {
        guard await doc.saveAs(target, prompter: prompter) else { return false }
        noteRecent(target)
        return true
    }

    /// Writes every dirty tab that has a file (Untitled tabs wait for close or quit).
    @discardableResult
    func saveAll(reason: SaveReason) async -> Bool {
        var ok = true
        for doc in tabs where doc.isDirty && doc.url != nil {
            if await !save(doc, reason: reason) { ok = false }
        }
        return ok
    }

    // MARK: Closing

    /// false = the user cancelled; the tab stays.
    @discardableResult
    func close(_ id: OpenDocument.ID) async -> Bool {
        guard let doc = document(id) else { return true }
        if doc.isDirty, await !resolveUnsaved(doc) { return false }
        remove(doc)
        return true
    }

    /// Stops at the first Cancel.
    func closeOthers(_ id: OpenDocument.ID) async {
        for other in tabs where other.id != id {
            guard await close(other.id) else { return }
        }
        activate(id)
    }

    /// Stops at the first Cancel.
    func closeToTheRight(_ id: OpenDocument.ID) async {
        guard let i = order.firstIndex(of: id) else { return }
        for other in tabs[(i + 1)...] {
            guard await close(other.id) else { return }
        }
        activate(id)
    }

    /// Before the app quits: every dirty tab is answered. false = Cancel, the app keeps running.
    func prepareToQuit() async -> Bool {
        for doc in tabs where doc.isDirty {
            guard await resolveUnsaved(doc) else { return false }
        }
        return true
    }

    /// A dirty tab is about to go away: Save / Don't Save / Cancel (TB-11, TB-30). A Save that did not write
    /// asks again, Don't Save drops the changes.
    private func resolveUnsaved(_ doc: OpenDocument) async -> Bool {
        // The question is about the tab the user sees. No conflict sheet here: the save asks before overwriting.
        select(doc.id)
        while true {
            switch await prompter.askToSave(doc) {
            case .cancel: return false
            case .discard: return true
            case .save:
                if await save(doc, reason: .explicit) { return true }
                if doc.url == nil { return false } // Save panel cancelled
            }
        }
    }

    /// The active tab passes to the right neighbour, else the left one (TB-3).
    private func remove(_ doc: OpenDocument) {
        doc.close()
        guard let i = order.firstIndex(of: doc.id) else { return }
        order.remove(at: i)
        documents.removeAll { $0.id == doc.id }
        shown.remove(doc.id)
        if activeID == doc.id {
            activeID = nil
            if !order.isEmpty { activate(order[min(i, order.count - 1)]) }
        }
    }

    private func noteRecent(_ url: URL) {
        guard recordsRecents else { return }
        RecentDocuments.shared.note(url)
    }
}
