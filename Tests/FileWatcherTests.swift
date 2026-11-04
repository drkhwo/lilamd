import AppKit
import XCTest
@testable import MDEditor

/// R3 step 4: changes made by other apps to the file of a tab (ARCH 2.6). Files are temporary;
/// a fake prompter answers the conflict sheet.
@MainActor
final class FileWatcherTests: XCTestCase {
    private var dir: URL!
    private var fake: FakePrompter!
    private var store: TabStore!
    private var savedDelay: Duration = .seconds(2)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "filewatcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fake = FakePrompter()
        store = TabStore(prompter: fake)
        store.recordsRecents = false
        savedDelay = OpenDocument.autosaveDelay
        OpenDocument.autosaveDelay = .seconds(60) // no autosave unless a test wants one
    }

    override func tearDown() async throws {
        for doc in store?.tabs ?? [] { doc.close() }
        store = nil
        OpenDocument.autosaveDelay = savedDelay
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    // XCTAssert's autoclosures cannot await.
    private func expectTrue(_ value: Bool, line: UInt = #line) { XCTAssertTrue(value, line: line) }
    private func expectFalse(_ value: Bool, line: UInt = #line) { XCTAssertFalse(value, line: line) }

    /// TB-23, C7: a clean tab takes the disk version without a question, for in-place writes and for
    /// atomic replacements (new inode). The disk version becomes the baseline for the next save.
    func testCleanTabReloadsWithoutQuestion() async throws {
        let url = try file("a.md", "Alpha\n")
        let doc = try store.open(url)
        try Data("Alpha\nAppended outside.\n".utf8).write(to: url)
        try await waitUntil(5, "in-place change reloaded") { doc.text == "Alpha\nAppended outside.\n" }
        XCTAssertFalse(doc.isDirty)

        try Data("Replaced\n".utf8).write(to: url, options: .atomic)
        try await waitUntil(5, "atomic replacement reloaded") { doc.text == "Replaced\n" }
        XCTAssertFalse(doc.isDirty)

        doc.editorChanged("Replaced\nmine\n")
        expectTrue(await store.save(doc))
        XCTAssertEqual(try text(url), "Replaced\nmine\n")
        XCTAssertEqual(fake.calls, [], "no conflict, no overwrite question")
    }

    /// TB-23 in the window: the editor of the visible tab shows the new text (the C7 smoke step in-process).
    func testCleanTabReloadsItsEditor() async throws {
        let url = try file("crlf.md", "One\r\nTwo\r\n")
        let wc = MainWindowController(store: store)
        defer { wc.window?.close() }
        wc.open([url])
        let doc = try XCTUnwrap(store.active)
        try await waitUntil(20, "editor ready") { doc.controller?.isReady == true }
        try Data("One\r\nTwo\r\nLine appended outside.\r\n".utf8).write(to: url)
        try await waitUntil(5, "editor reloaded") { doc.controller?.text == "One\r\nTwo\r\nLine appended outside.\r\n" }
        try await waitUntil(5, "page shows the line") {
            let shown = try await doc.controller?.evaluate("return mdeditor.root().textContent") as? String
            return shown?.contains("Line appended outside.") == true
        }
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(fake.calls, [])
    }

    /// Not UTF-8 on disk: the tab keeps its text (and the next save asks before overwriting).
    func testCleanTabKeepsTextWhenDiskIsNotUTF8() async throws {
        let url = try file("a.md", "Alpha\n")
        let doc = try store.open(url)
        try "caf\u{E9}\n".data(using: .isoLatin1)!.write(to: url)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(doc.text, "Alpha\n")
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(fake.calls, [])
    }

    /// TB-24: dirty active tab → the conflict sheet now. Keep: the text stays, autosave pauses, the next save
    /// asks before overwriting. A new foreign change asks again; Reload takes the disk version.
    func testDirtyActiveTabAsksNow() async throws {
        let url = try file("a.md", "Alpha\n")
        let doc = try store.open(url)
        doc.editorChanged("mine\n")
        fake.conflictResponse = FileWatcher.keepResponse
        try Data("theirs\n".utf8).write(to: url)
        try await waitUntil(5, "conflict sheet") { self.fake.calls == ["showConflict a.md"] }
        XCTAssertEqual(doc.text, "mine\n")
        XCTAssertTrue(doc.isDirty)
        XCTAssertTrue(doc.autosavePaused)
        XCTAssertFalse(doc.pendingConflict)

        fake.overwriteChoice = .cancel
        expectFalse(await store.save(doc))
        XCTAssertEqual(fake.calls, ["showConflict a.md", "askOverwrite a.md"])
        XCTAssertEqual(try text(url), "theirs\n")

        fake.conflictResponse = FileWatcher.reloadResponse
        try Data("theirs 2\n".utf8).write(to: url)
        try await waitUntil(5, "reloaded after the second sheet") { doc.text == "theirs 2\n" }
        XCTAssertEqual(fake.calls, ["showConflict a.md", "askOverwrite a.md", "showConflict a.md"])
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.autosavePaused)
    }

    /// ARCH 2.6: dirty hidden tab → no sheet now, autosave paused; the sheet comes when the tab is shown.
    func testDirtyHiddenTabAsksWhenShown() async throws {
        let a = try file("a.md", "Alpha\n")
        let docA = try store.open(a)
        let docB = try store.open(try file("b.md", "Beta\n"))
        XCTAssertEqual(store.activeID, docB.id)
        docA.editorChanged("mine\n")
        try Data("theirs\n".utf8).write(to: a)
        try await waitUntil(5, "pending conflict") { docA.pendingConflict }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.calls, [], "no sheet for a hidden tab")
        XCTAssertTrue(docA.autosavePaused)

        store.activate(docA.id)
        try await waitUntil(5, "sheet on activation") { self.fake.calls == ["showConflict a.md"] }
        XCTAssertFalse(docA.pendingConflict)
        XCTAssertEqual(docA.text, "mine\n")
        store.activate(docB.id)
        store.activate(docA.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.calls, ["showConflict a.md"], "answered once")
    }

    /// TB-25: our own write while the user keeps typing is not a foreign change.
    func testOwnSaveIsNotForeign() async throws {
        let url = try file("a.md", "Alpha\n")
        let doc = try store.open(url)
        doc.editorChanged("Alpha\nsaved\n")
        expectTrue(await store.save(doc))
        doc.editorChanged("Alpha\nsaved\ntyped after the save\n")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(doc.text, "Alpha\nsaved\ntyped after the save\n", "not reloaded")
        XCTAssertTrue(doc.isDirty)
        XCTAssertFalse(doc.pendingConflict)
        XCTAssertFalse(doc.autosavePaused)
        XCTAssertEqual(fake.calls, [], "no conflict")
        XCTAssertEqual(try text(url), "Alpha\nsaved\n")
    }

    /// TB-29: after Save As the watcher follows the new file; the old file is no longer the tab's.
    func testSaveAsWatchesTheNewFile() async throws {
        let old = try file("a.md", "Alpha\n")
        let doc = try store.open(old)
        doc.editorChanged("Alpha\nmoved\n")
        let new = dir.appending(path: "b.md")
        expectTrue(await store.saveAs(doc, to: new))
        try Data("old changed\n".utf8).write(to: old)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(doc.text, "Alpha\nmoved\n")
        try Data("new changed\n".utf8).write(to: new)
        try await waitUntil(5, "new file reloaded") { doc.text == "new changed\n" }
        XCTAssertEqual(fake.calls, [])
    }

    /// Untitled → Save As starts watching the file it was saved to.
    func testUntitledSavedAsIsWatched() async throws {
        let doc = store.newUntitled()
        doc.editorChanged("draft\n")
        let url = dir.appending(path: "draft.md")
        expectTrue(await store.saveAs(doc, to: url))
        try Data("changed outside\n".utf8).write(to: url)
        try await waitUntil(5, "reloaded") { doc.text == "changed outside\n" }
    }
}
