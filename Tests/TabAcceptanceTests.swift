import AppKit
import XCTest
@testable import MDEditor

/// R3 acceptance gaps (TB-*) that TabStoreTests / TabWindowTests / FileWatcherTests do not cover.
/// Same setup as TabWindowTests: a fake prompter, temporary files, real window and web views.
@MainActor
final class TabAcceptanceTests: XCTestCase {
    private var dir: URL!
    private var fake: FakePrompter!
    private var store: TabStore!
    private var wc: MainWindowController!
    private var defaults: [String: Any?] = [:]
    private var autosaveDelay = OpenDocument.autosaveDelay

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appending(path: "tabaccept-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for key in [ZoomPreference.key, EditorModePreference.key] { defaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(1.0, forKey: ZoomPreference.key)
        UserDefaults.standard.set(EditorMode.visual.rawValue, forKey: EditorModePreference.key)
        autosaveDelay = OpenDocument.autosaveDelay
        OpenDocument.autosaveDelay = .seconds(60)
        fake = FakePrompter()
        store = TabStore(prompter: fake)
        store.recordsRecents = false
        wc = MainWindowController(store: store)
    }

    override func tearDown() async throws {
        fake.closeChoice = .discard
        for doc in store.tabs { await store.close(doc.id) }
        wc.window?.close()
        wc = nil
        OpenDocument.autosaveDelay = autosaveDelay
        for (key, value) in defaults {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func ready(_ doc: OpenDocument) async throws {
        try await waitUntil(20, "editor of \(doc.displayName) ready") { doc.controller?.isReady == true }
    }

    private func key(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) async throws {
        let window = try XCTUnwrap(wc.window)
        if !window.isKeyWindow {
            wc.show()
            try? await waitUntil(2, "main window is key") { window.isKeyWindow }
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: keyCode)!
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(80))
    }

    // MARK: Opening

    /// TB-1, TB-16: five files from one open call are five tabs in one window; only the last one has a web view.
    /// Old behaviour (DocumentGroup): five windows, no tab model, so `store.tabs` would not exist.
    func testFiveFilesAreFiveTabsInOneWindow() async throws {
        let urls = try (1...5).map { try file("f\($0).md", "File \($0)\n") }
        wc.open(urls)
        XCTAssertEqual(store.tabs.map(\.displayName), ["f1.md", "f2.md", "f3.md", "f4.md", "f5.md"])
        XCTAssertEqual(store.active?.url, urls[4])
        let docs = store.tabs
        try await ready(docs[4])
        XCTAssertEqual(docs.filter { $0.controller != nil }.map(\.displayName), ["f5.md"], "no web view for tabs never shown")
        let mainWindows = NSApp.windows.filter { $0.windowController is MainWindowController && $0.isVisible }
        XCTAssertEqual(mainWindows.count, 1, "one visible main window")
    }

    /// TB-7: opening an open file again (Finder, `open -a`, ⌘O all end in `open(_:)`) focuses its tab.
    /// Old behaviour: DocumentGroup would not duplicate either, but a naive tab model would add a second tab.
    func testOpeningAnOpenFileFocusesItsTab() throws {
        let a = try file("a.md", "A\n")
        let b = try file("b.md", "B\n")
        wc.open([a, b])
        XCTAssertEqual(store.activeID, store.tab(for: b)?.id)
        wc.open([a])
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.active?.url, a)
        wc.open([a, b, a])
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.active?.url, a, "the last file of the batch is active")
    }

    /// TB-21: the error alert carries the text of `MarkdownDocumentError.notUTF8`; the other tabs stay.
    func testNotUTF8AlertTextAndOtherTabsUntouched() throws {
        let a = try file("a.md", "A\n")
        wc.open([a])
        let latin1 = try XCTUnwrap("caf\u{E9}\n".data(using: .isoLatin1))
        let bad = dir.appending(path: "bad.md")
        try latin1.write(to: bad)
        XCTAssertThrowsError(try store.open(bad)) { error in
            let alert = MainWindowController.makeOpenErrorAlert(url: bad, error: error)
            XCTAssertTrue(alert.messageText.contains("bad.md"), alert.messageText)
            let reason = (MarkdownDocumentError.notUTF8 as NSError).localizedFailureReason
            XCTAssertNotNil(reason)
            XCTAssertTrue(alert.informativeText.contains(reason ?? "?"), alert.informativeText)
        }
        XCTAssertEqual(store.tabs.map(\.displayName), ["a.md"])
        XCTAssertEqual(try Data(contentsOf: bad), latin1)
    }

    // MARK: Keys and shared settings

    /// TB-9, TB-26: ⌘2 / ⌘1 switch Visual / Source and never a tab; the mode reaches the hidden tab when it is shown.
    func testCmdDigitsSwitchModeNotTabs() async throws {
        let a = try file("a.md", "# Alpha\n\nText\n")
        let b = try file("b.md", "# Beta\n\nText\n")
        wc.open([a])
        let docA = try XCTUnwrap(store.active)
        try await ready(docA)
        wc.open([b])
        let docB = try XCTUnwrap(store.active)
        try await ready(docB)

        try await key("2", keyCode: 19, flags: .command)
        XCTAssertEqual(store.activeID, docB.id, "⌘2 did not switch the tab")
        XCTAssertEqual(UserDefaults.standard.string(forKey: EditorModePreference.key), EditorMode.source.rawValue)
        try await waitUntil(10, "active tab in source mode") { docB.controller?.mode == .source }
        XCTAssertEqual(docA.controller?.mode, .visual, "a hidden tab keeps its editor until shown (undo history)")

        store.activate(docA.id)
        try await waitUntil(10, "a.md follows the mode when shown") { docA.controller?.mode == .source }
        XCTAssertEqual(docA.text, "# Alpha\n\nText\n")
        XCTAssertFalse(docA.isDirty, "a mode switch is not an edit")

        try await key("1", keyCode: 18, flags: .command)
        XCTAssertEqual(store.activeID, docA.id, "⌘1 did not switch the tab")
        try await waitUntil(10, "visual mode again") { docA.controller?.mode == .visual }
    }

    // MARK: Save As

    /// TB-29: ⌘S in an Untitled tab runs Save As; the tab takes the new name, proxy icon and watcher.
    func testCmdSInUntitledRunsSaveAs() async throws {
        try requireForeground()
        let target = dir.appending(path: "from-untitled.md")
        fake.saveURL = target
        let doc = store.newUntitled()
        wc.show()
        try await ready(doc)
        doc.editorChanged("draft\n")
        XCTAssertNil(wc.window?.representedURL)
        try await key("s", keyCode: 1, flags: .command)
        try await waitUntil(5, "saved as") { doc.url == target }
        XCTAssertEqual(try Data(contentsOf: target), Data("draft\n".utf8))
        XCTAssertEqual(fake.calls, ["chooseSaveURL Untitled"])
        XCTAssertEqual(wc.window?.title, "from-untitled.md")
        XCTAssertEqual(wc.window?.representedURL, target)
        XCTAssertFalse(doc.isDirty)
    }

    /// TB-29: ⇧⌘S on a file tab writes the new file, renames the tab, leaves the old file as it was.
    func testShiftCmdSSavesUnderNewName() async throws {
        try requireForeground()
        let a = try file("a.md", "Alpha\n")
        let target = dir.appending(path: "copy.md")
        fake.saveURL = target
        wc.open([a])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        doc.editorChanged("Alpha changed\n")
        try await key("S", keyCode: 1, flags: [.command, .shift])
        try await waitUntil(5, "saved as") { doc.url == target }
        XCTAssertEqual(try Data(contentsOf: target), Data("Alpha changed\n".utf8))
        XCTAssertEqual(try Data(contentsOf: a), Data("Alpha\n".utf8), "the old file is not changed")
        XCTAssertEqual(wc.window?.title, "copy.md")
        XCTAssertEqual(wc.window?.representedURL, target)
        XCTAssertEqual(store.tabs.count, 1)
    }

    // MARK: Web process, close questions

    /// TB-35: a dead web process reloads the page, the text stays in `OpenDocument` and comes back in the editor.
    func testWebProcessCrashKeepsTextAndRecovers() async throws {
        let a = try file("a.md", "Alpha\n")
        wc.open([a])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        doc.editorChanged("Alpha edited\n")
        let controller = try XCTUnwrap(doc.controller)
        controller.webViewWebContentProcessDidTerminate(controller.webView)
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(doc.text, "Alpha edited\n")
        XCTAssertTrue(doc.isDirty)
        try await waitUntil(20, "editor ready again") { controller.isReady }
        let value = try await controller.evaluate("return mdeditor.getValue()") as? String
        XCTAssertEqual(value, controller.text)
        XCTAssertEqual(doc.text, "Alpha edited\n", "the reloaded page did not change the document")
    }

    /// TB-36: highlight.js is loaded once per page, not once per code block. With one load per block, a tab with
    /// big.md (500 code blocks) took 3 GB in its web process, and the 10th such tab never loaded.
    func testBigFileLoadsHighlightJSOnce() async throws {
        let big = dir.appending(path: "big.md")
        try FileManager.default.copyItem(at: Samples.url("big.md"), to: big)
        wc.open([big])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        let controller = try XCTUnwrap(doc.controller)
        try await waitUntil(10, "code blocks highlighted") {
            let n = try await controller.evaluate("return mdeditor.root().querySelectorAll('.vditor-ir__preview code.hljs').length") as? Int
            return (n ?? 0) >= 500
        }
        XCTAssertEqual(controller.requestLog.filter { $0.contains("/highlight.min.js") }.count, 1)
        XCTAssertEqual(controller.requestLog.filter { $0.contains("/third-languages.js") }.count, 1)
        XCTAssertFalse(doc.isDirty)
    }

    /// TB-13: Close Others asks for every Untitled tab with text; Don't Save drops it, the kept tab stays.
    func testCloseOthersAsksForEachDirtyUntitled() async throws {
        let keep = try store.open(try file("keep.md", "Keep\n"))
        let u1 = store.newUntitled(), u2 = store.newUntitled()
        u1.editorChanged("one\n")
        u2.editorChanged("two\n")
        fake.closeChoice = .discard
        await store.closeOthers(keep.id)
        XCTAssertEqual(fake.calls, ["askToSave Untitled", "askToSave Untitled 2"])
        XCTAssertEqual(store.tabs.map(\.displayName), ["keep.md"])
        XCTAssertEqual(store.activeID, keep.id)
    }

    /// TB-11 (Untitled): Save writes and closes; Don't Save closes without a file; Cancel keeps the tab.
    /// File tabs are written without a question (Stas, 05.11), see TabStoreTests.testCloseDirtyFileWritesWithoutQuestion.
    func testCloseUntitledSaveDontSaveCancel() async throws {
        let target = dir.appending(path: "u.md")
        let doc = store.newUntitled()
        doc.editorChanged("text\n")

        fake.closeChoice = .cancel
        let cancelled = await store.close(doc.id)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        fake.closeChoice = .discard
        let dropped = await store.close(doc.id)
        XCTAssertTrue(dropped)
        XCTAssertEqual(store.tabs.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let again = store.newUntitled()
        again.editorChanged("text\n")
        fake.closeChoice = .save
        fake.saveURL = target
        let saved = await store.close(again.id)
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: target), Data("text\n".utf8))
    }

    // MARK: Links

    /// TB-34: a plain click does nothing and ⌘-click opens the link, in a tab's own editor.
    func testLinkClickInTab() async throws {
        let a = try file("a.md", "See [site](https://example.com) now.\n")
        wc.open([a])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        let controller = try XCTUnwrap(doc.controller)
        var opened: [URL] = []
        controller.openExternally = { opened.append($0) }
        let click = """
        const link = document.querySelector('.vditor-ir [data-type=a] .vditor-ir__link');
        link.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, metaKey: meta}));
        """
        try await controller.evaluate(click, arguments: ["meta": false])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(opened, [])
        try await controller.evaluate(click, arguments: ["meta": true])
        try await waitUntil(3, "link opened") { !opened.isEmpty }
        XCTAssertEqual(opened, [URL(string: "https://example.com")!])
        XCTAssertFalse(doc.isDirty)
    }
}
