import AppKit
import XCTest
@testable import MDEditor

/// A prompter whose Save? sheet stays on screen for 600 ms (longer than the 200 ms autosave delay in these tests).
@MainActor
final class SlowPrompter: SavePrompting {
    var calls: [String] = []
    /// Runs when the Save? sheet appears (the sheet is on screen until it returns + 600 ms).
    var onAskToSave: (@MainActor (OpenDocument) async -> Void)?
    var closeChoice: CloseChoice = .discard

    func askToSave(_ doc: OpenDocument) async -> CloseChoice {
        calls.append("askToSave")
        await onAskToSave?(doc)
        try? await Task.sleep(for: .milliseconds(600))
        return closeChoice
    }
    func askOverwrite(_ doc: OpenDocument) async -> OverwriteChoice { calls.append("askOverwrite"); return .cancel }
    func chooseSaveURL(for doc: OpenDocument) async -> URL? { nil }
    func showConflict(_ doc: OpenDocument) async -> NSApplication.ModalResponse { FileWatcher.keepResponse }
    func report(_ error: Error, for doc: OpenDocument) async { calls.append("report") }
}

/// Regression for the round-1 critic probe (R3-tabs/critic/ZZCriticProbeTests.swift.txt): the autosave timer
/// wrote the file while the Save? sheet was up, so Don't Save lost to it. Since Stas's decision (05.11) a file tab
/// closes without a question; a question for a file tab remains only after a failed write, and autosave must
/// not write behind it.
@MainActor
final class AutosaveDuringSheetTests: XCTestCase {
    private var dir: URL!
    private var savedDelay = OpenDocument.autosaveDelay

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "sheet-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedDelay = OpenDocument.autosaveDelay
        OpenDocument.autosaveDelay = .milliseconds(200)
    }

    override func tearDown() async throws {
        OpenDocument.autosaveDelay = savedDelay
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(_ prompter: SavePrompting) -> TabStore {
        let store = TabStore(prompter: prompter)
        store.recordsRecents = false
        return store
    }

    /// The critic's scenario under the new rule: edit, ⌘W at once, a slow user. Nothing is asked; the edit is written.
    func testCloseRightAfterEditWritesWithoutQuestion() async throws {
        let url = dir.appending(path: "a.md")
        try Data("original\n".utf8).write(to: url)
        let prompter = SlowPrompter()
        let store = store(prompter)
        let doc = try store.open(url)
        doc.editorChanged("edited\n")
        let closed = await store.close(doc.id)
        XCTAssertTrue(closed)
        XCTAssertEqual(prompter.calls, [])
        XCTAssertEqual(try Data(contentsOf: url), Data("edited\n".utf8))
    }

    /// The write before closing fails (folder is read-only), so Save? appears. While it is on screen the folder
    /// becomes writable, a late edit arrives (starts the autosave timer) and the app loses focus
    /// (`applicationWillResignActive` → `saveAll(.autosave)`). Don't Save after 600 ms: the file is untouched.
    func testDontSaveWhileAutosaveFires() async throws {
        let url = dir.appending(path: "a.md")
        let original = Data("original\n".utf8)
        try original.write(to: url)
        let prompter = SlowPrompter()
        let store = store(prompter)
        let doc = try store.open(url)
        doc.editorChanged("edited\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        var autosaveWrote: Bool?
        prompter.onAskToSave = { _ in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.dir.path)
            doc.editorChanged("edited again\n")
            autosaveWrote = await store.saveAll(reason: .autosave)
        }
        let closed = await store.close(doc.id)
        XCTAssertTrue(closed)
        XCTAssertEqual(prompter.calls, ["report", "askToSave"])
        XCTAssertEqual(autosaveWrote, false, "saveAll(.autosave) must not write behind the sheet")
        try await Task.sleep(for: .milliseconds(400)) // a stray autosave would fire by now
        XCTAssertEqual(try Data(contentsOf: url), original, "Don't Save must leave the file as it was")
    }

    /// Round-2 critic probe (R3-tabs/round2/critic/ZZCriticR2Probe.swift.txt). ⌘Q: a.md cannot be written
    /// (read-only folder) → Save? → Don't Save. Then Untitled asks Save?; while that sheet is up the folder becomes
    /// writable and the user is slow (600 ms > 200 ms autosave delay). `resign`: the app also loses focus
    /// (`saveAll(.autosave)`). a.md was answered Don't Save, so it must stay the original until the app is gone.
    private func quitRace(resign: Bool) async throws {
        let a = dir.appending(path: "a.md")
        let original = Data("original\n".utf8)
        try original.write(to: a)
        let prompter = SlowPrompter()
        let store = store(prompter)
        let docA = try store.open(a)
        docA.editorChanged("discarded\n")
        let untitled = store.newUntitled()
        untitled.editorChanged("draft\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        var resignWrote: Bool?
        prompter.onAskToSave = { doc in
            guard doc.url == nil else { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.dir.path)
            if resign { resignWrote = await store.saveAll(reason: .autosave) }
        }
        let ok = await store.prepareToQuit()
        XCTAssertTrue(ok)
        XCTAssertEqual(prompter.calls, ["report", "askToSave", "askToSave"])
        if resign { XCTAssertEqual(resignWrote, false, "saveAll(.autosave) must not write a tab answered Don't Save") }
        try await Task.sleep(for: .milliseconds(400)) // a re-armed autosave timer would fire by now
        XCTAssertEqual(try Data(contentsOf: a), original, "Don't Save on a.md, yet a.md was written during the quit")
        for doc in store.tabs { doc.close() }
    }

    func testQuitDontSaveTimerOnly() async throws { try await quitRace(resign: false) }
    func testQuitDontSaveFileTabThenSlowUntitledSheet() async throws { try await quitRace(resign: true) }

    /// ⌘Q: another app changed a.md, Cancel in the overwrite question, Don't Save. While Untitled asks, the
    /// autosave timer must not come back with a second overwrite question in the middle of the quit.
    func testQuitAfterOverwriteCancelAsksOnce() async throws {
        let a = dir.appending(path: "a.md")
        let theirs = Data("theirs\n".utf8)
        try Data("original\n".utf8).write(to: a)
        let prompter = SlowPrompter()
        let store = store(prompter)
        let docA = try store.open(a)
        docA.editorChanged("mine\n")
        try theirs.write(to: a)
        let untitled = store.newUntitled()
        untitled.editorChanged("draft\n")
        let ok = await store.prepareToQuit()
        XCTAssertTrue(ok)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(prompter.calls.filter { $0 == "askOverwrite" }.count, 1, "\(prompter.calls)")
        XCTAssertEqual(try Data(contentsOf: a), theirs)
        for doc in store.tabs { doc.close() }
    }

    /// Cancel in a quit question keeps the app running: the holds go away and autosave writes again.
    func testQuitCancelResumesAutosave() async throws {
        let a = dir.appending(path: "a.md")
        try Data("original\n".utf8).write(to: a)
        let prompter = SlowPrompter()
        prompter.closeChoice = .cancel
        let store = store(prompter)
        let docA = try store.open(a)
        let untitled = store.newUntitled()
        untitled.editorChanged("draft\n")
        let ok = await store.prepareToQuit()
        XCTAssertFalse(ok)
        docA.editorChanged("after cancel\n")
        try await waitUntil(3, "autosave after a cancelled quit") { !docA.isDirty }
        XCTAssertEqual(try Data(contentsOf: a), Data("after cancel\n".utf8))
        for doc in store.tabs { doc.close() }
    }

    /// A closed tab is never autosaved, even by a `saveAll` that took its tab list before the close.
    func testClosedTabIsNotAutosaved() async throws {
        let a = dir.appending(path: "a.md")
        let original = Data("original\n".utf8)
        try original.write(to: a)
        let doc = try OpenDocument(contentsOf: a)
        doc.editorChanged("dropped\n")
        doc.close()
        let wrote = await doc.save(prompter: FakePrompter(), reason: .autosave)
        XCTAssertFalse(wrote)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try Data(contentsOf: a), original)
    }

    /// Cancel keeps the tab: autosave works again afterwards.
    func testCancelResumesAutosave() async throws {
        let url = dir.appending(path: "a.md")
        let theirs = Data("theirs\n".utf8)
        try Data("original\n".utf8).write(to: url)
        let prompter = FakePrompter()
        let store = store(prompter)
        let doc = try store.open(url)
        try theirs.write(to: url)
        doc.editorChanged("mine\n")
        prompter.overwriteChoice = .cancel
        prompter.closeChoice = .cancel
        let closed = await store.close(doc.id)
        XCTAssertFalse(closed)
        XCTAssertEqual(prompter.calls, ["askOverwrite a.md", "askToSave a.md"])
        prompter.overwriteChoice = .overwrite
        doc.editorChanged("mine 2\n")
        try await waitUntil(3, "autosave after Cancel") { !doc.isDirty }
        XCTAssertEqual(try Data(contentsOf: url), Data("mine 2\n".utf8))
        doc.close()
    }
}
