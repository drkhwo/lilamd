import AppKit
import CryptoKit
import XCTest
@testable import MDEditor

/// R3 tab model without windows or web views. Files are copies of `samples/` in a temporary folder.
@MainActor
final class TabStoreTests: XCTestCase {
    var dir: URL!
    var prompter: FakePrompter!
    var store: TabStore!
    private var savedDelay: Duration = .seconds(2)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "tabstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: Samples.dir.path) where name.hasSuffix(".md") {
            try FileManager.default.copyItem(at: Samples.url(name), to: dir.appending(path: name))
        }
        // Not in samples/ (C-12): BOM, and no final newline.
        try (MarkdownDocument.utf8BOM + Data("# BOM\n\nText.\n".utf8)).write(to: dir.appending(path: "bom.md"))
        try Data("# No newline\n\nLast line".utf8).write(to: dir.appending(path: "no-final-newline.md"))
        prompter = FakePrompter()
        store = TabStore(prompter: prompter)
        store.recordsRecents = false
        savedDelay = OpenDocument.autosaveDelay
    }

    override func tearDown() async throws {
        OpenDocument.autosaveDelay = savedDelay
        for doc in store?.tabs ?? [] { doc.close() }
        store = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func file(_ name: String) -> URL { dir.appending(path: name) }
    private func bytes(_ name: String) throws -> Data { try Data(contentsOf: file(name)) }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    // XCTAssert's autoclosures cannot await.
    private func expectTrue(_ value: Bool, _ message: String = "", line: UInt = #line) { XCTAssertTrue(value, message, line: line) }
    private func expectFalse(_ value: Bool, _ message: String = "", line: UInt = #line) { XCTAssertFalse(value, message, line: line) }

    // MARK: Open, dedupe, Untitled

    /// TB-22, TB-16 (model): one tab per file whatever path leads to it; no web view before the first show.
    func testOpenSameFileByAnyPathGivesOneTab() throws {
        let fm = FileManager.default
        let doc = try store.open(file("sample.md"))
        XCTAssertNil(doc.controller)
        XCTAssertEqual(doc.displayName, "sample.md")
        XCTAssertFalse(doc.isDirty)
        let other = try store.open(file("crlf.md"))
        XCTAssertEqual(store.activeID, other.id)

        XCTAssertTrue(try store.open(file("sample.md")) === doc)
        XCTAssertEqual(store.activeID, doc.id)
        XCTAssertTrue(try store.open(dir.appending(path: "sub/../sample.md")) === doc)

        let link = file("link.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: file("sample.md"))
        XCTAssertTrue(try store.open(link) === doc)

        let hard = file("hard.md")
        try fm.linkItem(at: file("sample.md"), to: hard)
        XCTAssertTrue(try store.open(hard) === doc)

        let caseSensitive = try dir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true
        if !caseSensitive {
            XCTAssertTrue(try store.open(file("SAMPLE.md")) === doc)
        }
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.tabs.map(\.displayName), ["sample.md", "crlf.md"])
        XCTAssertEqual(store.activeID, doc.id)
    }

    func testNewUntitledNames() async {
        let a = store.newUntitled()
        let b = store.newUntitled()
        let c = store.newUntitled()
        XCTAssertEqual([a, b, c].map(\.displayName), ["Untitled", "Untitled 2", "Untitled 3"])
        XCTAssertNil(a.url)
        XCTAssertEqual(store.activeID, c.id)
        expectTrue(await store.close(a.id)) // empty Untitled: closes without a question
        XCTAssertEqual(store.newUntitled().displayName, "Untitled")
        XCTAssertEqual(prompter.calls, [])
    }

    /// TB-21: the error comes through, no tab is added, the file is not touched.
    func testNotUTF8FileIsNotOpened() throws {
        let latin1 = "caf\u{E9} na\u{EF}ve\n".data(using: .isoLatin1)!
        try latin1.write(to: file("latin1.md"))
        try store.open(file("sample.md"))
        XCTAssertThrowsError(try store.open(file("latin1.md"))) { error in
            XCTAssertEqual(error as? MarkdownDocumentError, .notUTF8)
            XCTAssertNotNil((error as NSError).localizedFailureReason)
        }
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.active?.displayName, "sample.md")
        XCTAssertEqual(try bytes("latin1.md"), latin1)
    }

    // MARK: Order and activation

    /// TB-3: new tab is active; closing the active tab activates the right neighbour, else the left one.
    func testActivationAfterClose() async throws {
        let a = try store.open(file("sample.md"))
        let b = try store.open(file("crlf.md"))
        let c = try store.open(file("cyrillic.md"))
        let d = try store.open(file("empty.md"))
        XCTAssertEqual(store.activeID, d.id)
        XCTAssertEqual(store.shown, [a.id, b.id, c.id, d.id])

        store.activate(b.id)
        expectTrue(await store.close(b.id))
        XCTAssertEqual(store.activeID, c.id)
        expectTrue(await store.close(d.id)) // not active: active stays
        XCTAssertEqual(store.activeID, c.id)
        expectTrue(await store.close(c.id)) // rightmost: left neighbour
        XCTAssertEqual(store.activeID, a.id)
        expectTrue(await store.close(a.id))
        XCTAssertNil(store.activeID)
        XCTAssertEqual(store.tabs.count, 0)
        XCTAssertEqual(store.documents.count, 0)
        XCTAssertEqual(store.shown, [])
    }

    /// TB-8 (model), TB-14 (model): next/previous wrap around; move keeps the active tab and the creation order.
    func testNextPreviousWrapAndMove() throws {
        let a = try store.open(file("sample.md"))
        let b = try store.open(file("crlf.md"))
        let c = try store.open(file("cyrillic.md"))
        store.activateNext()
        XCTAssertEqual(store.activeID, a.id)
        store.activatePrevious()
        XCTAssertEqual(store.activeID, c.id)
        store.activatePrevious()
        XCTAssertEqual(store.activeID, b.id)

        a.editorChanged("edited")
        store.move(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(store.tabs.map(\.id), [b.id, c.id, a.id])
        store.move(fromOffsets: [1, 2], toOffset: 0)
        XCTAssertEqual(store.tabs.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(store.activeID, b.id)
        XCTAssertEqual(store.documents.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(a.text, "edited")
        XCTAssertTrue(a.isDirty)

        store.activateNext() // b is last now
        XCTAssertEqual(store.activeID, c.id)
    }

    /// TB-13 (model).
    func testCloseOthersAndToTheRight() async throws {
        let names = ["sample.md", "crlf.md", "cyrillic.md", "empty.md", "big.md"]
        let docs = try names.map { try store.open(file($0)) }
        await store.closeToTheRight(docs[2].id)
        XCTAssertEqual(store.tabs.map(\.displayName), ["sample.md", "crlf.md", "cyrillic.md"])
        XCTAssertEqual(store.activeID, docs[2].id)
        await store.closeOthers(docs[1].id)
        XCTAssertEqual(store.tabs.map(\.displayName), ["crlf.md"])
        XCTAssertEqual(store.activeID, docs[1].id)
    }

    /// Cancel in a question stops Close Others; tabs after it stay.
    func testCloseOthersStopsAtCancel() async throws {
        let a = try store.open(file("sample.md"))
        let u = store.newUntitled()
        u.editorChanged("draft")
        let b = try store.open(file("crlf.md"))
        prompter.closeChoice = .cancel
        await store.closeOthers(b.id)
        XCTAssertEqual(store.tabs.map(\.id), [u.id, b.id])
        XCTAssertEqual(prompter.calls, ["askToSave Untitled"])
        XCTAssertEqual(store.activeID, u.id) // asked about the tab the user sees
        XCTAssertNil(store.document(a.id))
    }

    // MARK: Dirty state

    /// TB-4: dirty after an edit; clean after save or after returning to the original text.
    func testDirtyFollowsText() async throws {
        let doc = try store.open(file("sample.md"))
        let original = doc.text
        doc.editorChanged(original + "more\n")
        XCTAssertTrue(doc.isDirty)
        doc.editorChanged(original)
        XCTAssertFalse(doc.isDirty)

        doc.editorChanged(original + "more\n")
        expectTrue(await store.save(doc))
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try MarkdownDocument(data: bytes("sample.md")).text, original + "more\n")
        doc.editorChanged(original)
        XCTAssertTrue(doc.isDirty) // the saved text is the new baseline
        XCTAssertEqual(prompter.calls, [])
    }

    // MARK: Bytes

    /// TB-20: saving an untouched tab writes the bytes that were read, for every sample.
    func testForcedSaveOfUntouchedTabKeepsBytes() async throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }.sorted()
        for required in ["crlf.md", "cyrillic.md", "empty.md", "big.md", "sample.md", "bom.md", "no-final-newline.md"] {
            XCTAssertTrue(names.contains(required), required)
        }
        for name in names {
            let before = try bytes(name)
            let doc = try store.open(file(name))
            expectTrue(await doc.save(prompter: prompter, force: true), name)
            XCTAssertEqual(sha(try bytes(name)), sha(before), name)
            XCTAssertFalse(doc.isDirty, name)
        }
        XCTAssertEqual(prompter.calls, [])
    }

    /// An untouched tab is never written: ⌘S and autosave leave the modification date alone.
    func testUntouchedTabIsNotWritten() async throws {
        let url = file("sample.md")
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let doc = try store.open(url)
        let original = doc.text
        expectTrue(await store.save(doc))
        doc.editorChanged(original + "x")
        doc.editorChanged(original) // back to the file's text
        expectTrue(await store.saveAll(reason: .autosave))
        expectTrue(await store.close(doc.id))
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime, old)
    }

    /// ARCH 2.4: the write keeps the file's permissions and writes through a symlink (it stays a symlink).
    func testSaveKeepsPermissionsAndSymlink() async throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file("sample.md").path)
        let link = file("link.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: file("sample.md"))
        let doc = try store.open(link)
        doc.editorChanged(doc.text + "via link\n")
        expectTrue(await store.save(doc))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), file("sample.md").path)
        XCTAssertTrue(String(decoding: try bytes("sample.md"), as: UTF8.self).hasSuffix("via link\n"))
        XCTAssertEqual((try fm.attributesOfItem(atPath: file("sample.md").path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(prompter.calls, [])
    }

    // MARK: Foreign changes

    /// TB-28: a file changed by another app is not overwritten without a question; Cancel keeps it.
    func testSaveAsksBeforeOverwritingForeignChange() async throws {
        let doc = try store.open(file("sample.md"))
        doc.editorChanged("mine\n")
        let foreign = Data("theirs\n".utf8)
        try foreign.write(to: file("sample.md"))

        prompter.overwriteChoice = .cancel
        expectFalse(await store.save(doc))
        XCTAssertEqual(prompter.calls, ["askOverwrite sample.md"])
        XCTAssertEqual(try bytes("sample.md"), foreign)
        XCTAssertTrue(doc.isDirty)

        prompter.overwriteChoice = .overwrite
        expectTrue(await store.save(doc))
        XCTAssertEqual(try bytes("sample.md"), Data("mine\n".utf8))
        XCTAssertFalse(doc.isDirty)

        // Our own write is the new baseline: the next save does not ask.
        doc.editorChanged("mine again\n")
        expectTrue(await store.save(doc))
        XCTAssertEqual(prompter.calls.count, 2)
        XCTAssertEqual(try bytes("sample.md"), Data("mine again\n".utf8))
    }

    // MARK: Autosave

    func testAutosaveWritesAfterDelay() async throws {
        OpenDocument.autosaveDelay = .milliseconds(100)
        let doc = try store.open(file("crlf.md"))
        let edited = doc.text + "Autosaved\r\n"
        doc.editorChanged(edited)
        XCTAssertTrue(doc.isDirty)
        try await waitUntil(3, "autosave") { !doc.isDirty }
        XCTAssertEqual(try MarkdownDocument(data: bytes("crlf.md")).text, edited)
        XCTAssertEqual(prompter.calls, [])
    }

    /// Cancel on "overwrite?" during autosave pauses autosave of that tab until an explicit save.
    func testAutosaveCancelPausesUntilExplicitSave() async throws {
        OpenDocument.autosaveDelay = .milliseconds(100)
        let doc = try store.open(file("sample.md"))
        try Data("theirs\n".utf8).write(to: file("sample.md"))
        prompter.overwriteChoice = .cancel
        doc.editorChanged("mine\n")
        try await waitUntil(3, "overwrite question") { self.prompter.calls.count == 1 }
        XCTAssertTrue(doc.autosavePaused)
        doc.editorChanged("mine 2\n")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(prompter.calls, ["askOverwrite sample.md"])
        XCTAssertEqual(try bytes("sample.md"), Data("theirs\n".utf8))

        prompter.overwriteChoice = .overwrite
        expectTrue(await store.save(doc))
        XCTAssertFalse(doc.autosavePaused)
        XCTAssertEqual(try bytes("sample.md"), Data("mine 2\n".utf8))
    }

    // MARK: Close, quit, Save As

    /// TB-11 (model): a dirty tab with a file asks. Cancel keeps the tab and the file; Don't Save closes without
    /// writing; Save writes and closes.
    func testCloseDirtyFileAsksSaveDontSaveCancel() async throws {
        let original = try bytes("sample.md")
        let doc = try store.open(file("sample.md"))
        doc.editorChanged("closing\n")

        prompter.closeChoice = .cancel
        expectFalse(await store.close(doc.id))
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(try bytes("sample.md"), original)

        prompter.closeChoice = .discard
        expectTrue(await store.close(doc.id))
        XCTAssertEqual(store.tabs.count, 0)
        XCTAssertEqual(try bytes("sample.md"), original)

        let again = try store.open(file("sample.md"))
        again.editorChanged("closing\n")
        prompter.closeChoice = .save
        expectTrue(await store.close(again.id))
        XCTAssertEqual(try bytes("sample.md"), Data("closing\n".utf8))
        XCTAssertEqual(prompter.calls, ["askToSave sample.md", "askToSave sample.md", "askToSave sample.md"])
    }

    func testCloseUntitledWithText() async throws {
        let target = file("saved-untitled.md")
        let doc = store.newUntitled()
        doc.editorChanged("draft\n")

        prompter.closeChoice = .cancel
        expectFalse(await store.close(doc.id))
        XCTAssertEqual(store.tabs.count, 1)

        prompter.closeChoice = .save
        prompter.saveURL = nil // Save panel cancelled: the tab stays
        expectFalse(await store.close(doc.id))
        XCTAssertEqual(store.tabs.count, 1)

        prompter.saveURL = target
        expectTrue(await store.close(doc.id))
        XCTAssertEqual(try Data(contentsOf: target), Data("draft\n".utf8))
        XCTAssertEqual(prompter.calls, ["askToSave Untitled", "askToSave Untitled", "chooseSaveURL Untitled",
                                        "askToSave Untitled", "chooseSaveURL Untitled"])

        let other = store.newUntitled()
        other.editorChanged("dropped\n")
        prompter.closeChoice = .discard
        expectTrue(await store.close(other.id))
        XCTAssertEqual(store.tabs.count, 0)
    }

    /// TB-30 (model): quit asks for every dirty tab; Cancel keeps the app running and the file untouched.
    func testPrepareToQuit() async throws {
        let original = try bytes("sample.md")
        let doc = try store.open(file("sample.md"))
        doc.editorChanged("quit\n")
        let untitled = store.newUntitled()
        untitled.editorChanged("draft\n")

        prompter.closeChoice = .cancel
        expectFalse(await store.prepareToQuit())
        XCTAssertEqual(prompter.calls, ["askToSave sample.md"])
        XCTAssertEqual(try bytes("sample.md"), original)
        XCTAssertEqual(store.activeID, doc.id, "the question is about the visible tab")

        prompter.closeChoice = .discard
        expectTrue(await store.prepareToQuit())
        XCTAssertEqual(prompter.calls, ["askToSave sample.md", "askToSave sample.md", "askToSave Untitled"])
        XCTAssertEqual(try bytes("sample.md"), original)
    }

    /// TB-29 (model): Save As moves the tab to the new file; the old file is not touched.
    func testSaveAsMovesTabToNewFile() async throws {
        let before = try bytes("sample.md")
        let doc = try store.open(file("sample.md"))
        doc.editorChanged("renamed\n")
        let target = file("renamed.md")
        expectTrue(await store.saveAs(doc, to: target))
        XCTAssertEqual(doc.url, target)
        XCTAssertEqual(doc.displayName, "renamed.md")
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try Data(contentsOf: target), Data("renamed\n".utf8))
        XCTAssertEqual(try bytes("sample.md"), before)
        XCTAssertTrue(try store.open(target) === doc)
        XCTAssertEqual(try store.open(file("sample.md")).displayName, "sample.md")
        XCTAssertEqual(store.tabs.count, 2)
    }
}
