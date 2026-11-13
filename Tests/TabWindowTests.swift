import AppKit
import XCTest
@testable import MDEditor

/// The main window with real tabs and web views (R3). A fake prompter answers every question;
/// files are temporary copies, `samples/` is never written.
@MainActor
final class TabWindowTests: XCTestCase {
    private var dir: URL!
    private var fake: FakePrompter!
    private var store: TabStore!
    private var wc: MainWindowController!
    private var defaults: [String: Any?] = [:]
    private var autosaveDelay = OpenDocument.autosaveDelay

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appending(path: "tabwindow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Same bundle id as the installed app: put its settings back afterwards.
        for key in [ZoomPreference.key, EditorModePreference.key] { defaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(1.0, forKey: ZoomPreference.key)
        UserDefaults.standard.set(EditorMode.visual.rawValue, forKey: EditorModePreference.key)
        autosaveDelay = OpenDocument.autosaveDelay
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

    // MARK: Helpers

    private func file(_ name: String, _ text: String, in folder: String? = nil) throws -> URL {
        let parent = folder.map { dir.appending(path: $0) } ?? dir!
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func ready(_ doc: OpenDocument) async throws {
        try await waitUntil(20, "editor of \(doc.displayName) ready") { doc.controller?.isReady == true }
    }

    @discardableResult
    private func js(_ doc: OpenDocument, _ code: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await XCTUnwrap(doc.controller).evaluate(code, arguments: args)
    }

    /// Places the caret after `word` and types through the browser's editing pipeline (real `input` events).
    private func type(_ s: String, after word: String, in doc: OpenDocument) async throws {
        let web = try XCTUnwrap(doc.controller?.webView)
        web.window?.makeKeyAndOrderFront(nil)
        web.window?.makeFirstResponder(web)
        let ok = try await js(doc, """
        mdeditor.instance.focus();
        const walker = document.createTreeWalker(mdeditor.root(), NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const n = walker.currentNode; const i = n.textContent.indexOf(word);
          if (i >= 0) {
            const r = document.createRange(); r.setStart(n, i + word.length); r.collapse(true);
            const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
            document.execCommand('insertText', false, s); return true;
          }
        }
        return false;
        """, ["word": word, "s": s]) as? Bool
        XCTAssertEqual(ok, true, "word \(word) not found in \(doc.displayName)")
    }

    /// A native key event through NSApp, the same path as the keyboard (menu key equivalents first).
    private func key(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) async throws {
        let window = try XCTUnwrap(wc.window)
        // Another app may have taken the focus during the run: key equivalents reach the menu only in the active app.
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

    // MARK: Window

    /// TB-2, REG-12: the single window opens at the default size.
    func testWindowHasDefaultSizeAndNoSystemTabs() throws {
        let window = try XCTUnwrap(wc.window)
        let content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(content.width, MDEditorApp.defaultWindowSize.width, accuracy: 1)
        XCTAssertEqual(content.height, MDEditorApp.defaultWindowSize.height, accuracy: 1)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertFalse(window.isReleasedWhenClosed)
    }

    /// Risk 4 of ARCH 2.9: the Visual / Source picker reaches the AppKit window's toolbar.
    func testModePickerIsInTheToolbar() async throws {
        let a = try file("a.md", "Alpha\n")
        wc.open([a])
        try await waitUntil(5, "toolbar with an item") { (self.wc.window?.toolbar?.items.count ?? 0) > 0 }
    }

    /// TB-15: title and proxy icon follow the active tab; Untitled has no represented URL.
    func testTitleAndRepresentedURLFollowActiveTab() async throws {
        let a = try file("a.md", "Alpha\n")
        let b = try file("b.md", "Beta\n")
        wc.open([a, b])
        let window = try XCTUnwrap(wc.window)
        XCTAssertEqual(window.title, "b.md")
        XCTAssertEqual(window.representedURL, b)
        store.newUntitled()
        XCTAssertEqual(window.title, "Untitled")
        XCTAssertNil(window.representedURL)
        let docA = try XCTUnwrap(store.tab(for: a))
        store.activate(docA.id)
        XCTAssertEqual(window.title, "a.md")
        XCTAssertEqual(window.representedURL, a)
        XCTAssertFalse(window.isDocumentEdited)
        OpenDocument.autosaveDelay = .seconds(60)
        docA.editorChanged("Alpha edited\n")
        XCTAssertTrue(window.isDocumentEdited)
    }

    /// TB-16: a tab gets its web view when it is first shown, not when it is opened.
    func testWebViewIsCreatedOnFirstShow() async throws {
        let a = try file("a.md", "Alpha\n")
        let b = try file("b.md", "Beta\n")
        let c = try file("c.md", "Gamma\n")
        wc.open([a, b, c])
        let docA = try XCTUnwrap(store.tab(for: a)), docC = try XCTUnwrap(store.tab(for: c))
        try await ready(docC)
        XCTAssertNil(docA.controller, "a.md was never shown")
        XCTAssertNil(try XCTUnwrap(store.tab(for: b)).controller)
        store.activate(docA.id)
        try await ready(docA)
        XCTAssertNotNil(docC.controller, "a hidden tab keeps its web view")
    }

    /// TB-10: ⌘W closes the active tab; after the last one the same visible window shows the start screen.
    func testCmdWClosesActiveTabThenShowsStartScreen() async throws {
        try requireForeground()
        let a = try file("a.md", "Alpha\n")
        let b = try file("b.md", "Beta\n")
        wc.open([a, b])
        try await ready(try XCTUnwrap(store.active))
        try await key("w", keyCode: 13, flags: .command)
        try await waitUntil(5, "b.md closed") { self.store.tabs.count == 1 }
        XCTAssertEqual(store.active?.url, a)
        try await key("w", keyCode: 13, flags: .command)
        try await waitUntil(5, "last tab closed") { self.store.tabs.isEmpty }
        XCTAssertEqual(store.contentState, .startScreen)
        XCTAssertEqual(wc.window?.isVisible, true)
        XCTAssertEqual(fake.calls, [], "clean tabs close without questions")
    }

    /// File menu: exactly one ⌘W (Close Tab); the NSDocument items are gone (TB-27, TB-32).
    func testFileMenuHasCloseTabOnceAndNoDocumentItems() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let titles = file.items.map(\.title)
        for title in ["New", "Open…", "Close Tab", "Save", "Save As…"] { XCTAssertTrue(titles.contains(title), "\(title) in \(titles)") }
        for title in ["Close", "Close All", "Duplicate", "Rename…", "Move To…", "Revert To Saved", "Revert To"] {
            XCTAssertFalse(titles.contains(title), "\(title) in \(titles)")
        }
        func all(_ m: NSMenu) -> [NSMenuItem] { m.items + m.items.compactMap(\.submenu).flatMap(all) }
        let cmdW = all(menu).filter { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == [.command] }
        XCTAssertEqual(cmdW.map(\.title), ["Close Tab"])
        let saveAs = try XCTUnwrap(file.items.first { $0.title == "Save As…" })
        XCTAssertEqual(saveAs.keyEquivalent.lowercased(), "s")
        XCTAssertEqual(saveAs.keyEquivalentModifierMask, [.command, .shift])
    }

    /// Open Recent with Clear Menu; Show Next / Previous Tab once each (no system window-tab items) (TB-8, TB-9).
    func testOpenRecentAndTabSwitchingMenus() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let recent = try XCTUnwrap(file.items.first { $0.title == "Open Recent" }?.submenu, "File > Open Recent")
        recent.update()
        XCTAssertTrue(recent.items.contains { $0.title == "Clear Menu" }, "\(recent.items.map(\.title))")
        func all(_ m: NSMenu) -> [NSMenuItem] { m.items + m.items.compactMap(\.submenu).flatMap(all) }
        let next = all(menu).filter { $0.title == "Show Next Tab" }
        let previous = all(menu).filter { $0.title == "Show Previous Tab" }
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(previous.count, 1)
        XCTAssertEqual(next.first?.keyEquivalentModifierMask, [.control])
        XCTAssertEqual(previous.first?.keyEquivalentModifierMask.contains(.control), true)
    }

    /// TB-8: ⌃Tab and ⇧⌘] go right, ⌃⇧Tab and ⇧⌘[ go left, both wrap around.
    func testTabKeysSwitchAndWrap() async throws {
        let urls = try ["a.md", "b.md", "c.md"].map { try file($0, "Text of \($0)\n") }
        wc.open(urls)
        let docs = try urls.map { try XCTUnwrap(store.tab(for: $0)) }
        try await ready(docs[2])
        try await key("\t", keyCode: 48, flags: .control)
        XCTAssertEqual(store.active?.displayName, "a.md", "⌃Tab after the last tab")
        try await key("}", keyCode: 30, flags: [.command, .shift])
        XCTAssertEqual(store.active?.displayName, "b.md", "⇧⌘]")
        try await key("\t", keyCode: 48, flags: [.control, .shift])
        XCTAssertEqual(store.active?.displayName, "a.md", "⌃⇧Tab")
        try await key("{", keyCode: 33, flags: [.command, .shift])
        XCTAssertEqual(store.active?.displayName, "c.md", "⇧⌘[ before the first tab")
        XCTAssertEqual(store.tabs.map(\.displayName), ["a.md", "b.md", "c.md"], "order unchanged")
    }

    /// ARCH 2.7: ⌃Tab in a table cell switches the tab; Vditor's Tab (next cell) does not run.
    func testCtrlTabInTableCellSwitchesTabAndKeepsCaret() async throws {
        let table = "| Name | Value |\n|------|-------|\n| alpha | 1 |\n"
        let a = try file("a.md", table)
        let b = try file("b.md", "Beta\n")
        wc.open([b, a])
        let docA = try XCTUnwrap(store.tab(for: a)), docB = try XCTUnwrap(store.tab(for: b))
        try await ready(docA)
        let web = try XCTUnwrap(docA.controller?.webView)
        web.window?.makeFirstResponder(web)
        let placed = try await js(docA, """
        mdeditor.instance.focus();
        const cell = [...document.querySelectorAll('.vditor-ir td')].find(td => td.textContent.includes('alpha'));
        if (!cell) return false;
        const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT); walker.nextNode();
        const r = document.createRange(); r.setStart(walker.currentNode, 'alpha'.length); r.collapse(true);
        const s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
        """) as? Bool
        XCTAssertEqual(placed, true, "caret in the alpha cell")
        // A hidden web view loses its DOM selection, so the proof is that the page never saw the key.
        try await js(docA, "window.tabKeys = 0; document.addEventListener('keydown', e => { if (e.key === 'Tab') window.tabKeys++ }, true)")
        try await key("\t", keyCode: 48, flags: .control)
        XCTAssertEqual(store.activeID, docB.id)
        try await Task.sleep(for: .milliseconds(300))
        let seen = try await js(docA, "return window.tabKeys") as? Int
        XCTAssertEqual(seen, 0, "Vditor got no Tab: the caret did not move to the next cell")
        XCTAssertEqual(docA.text, table)
        XCTAssertFalse(docA.isDirty)
        // The listener works: a plain Tab in the visible tab reaches the page.
        store.activate(docA.id)
        try await Task.sleep(for: .milliseconds(300))
        web.window?.makeFirstResponder(web)
        try await key("\t", keyCode: 48, flags: [])
        try await waitUntil(3, "plain Tab seen by the page") { (try await self.js(docA, "return window.tabKeys") as? Int ?? 0) > 0 }
    }

    // MARK: Editors in tabs

    /// TB-17, TB-18: ⌘Z from the menu acts on the active tab only; A's undo history and scroll position
    /// survive a trip to B and back.
    func testUndoGoesToActiveTabAndSurvivesSwitch() async throws {
        try requireForeground()
        OpenDocument.autosaveDelay = .seconds(60)
        let long = (1...200).map { "Paragraph \($0) of a long file." }.joined(separator: "\n\n") + "\n"
        let a = try file("a.md", long)
        let b = try file("b.md", "Beta text\n")
        wc.open([a])
        let docA = try XCTUnwrap(store.active)
        try await ready(docA)
        try await type(" EDITED", after: "Paragraph 150 of a long file.", in: docA)
        try await waitUntil(5, "edit in a.md") { docA.text.contains("Paragraph 150 of a long file. EDITED") }
        try await Task.sleep(for: .milliseconds(300))
        try await js(docA, "const s = document.querySelector('.vditor-ir .vditor-reset'); s.scrollTop = 1500")
        let scroll = try await js(docA, "return document.querySelector('.vditor-ir .vditor-reset').scrollTop") as! Double

        wc.open([b])
        let docB = try XCTUnwrap(store.active)
        try await ready(docB)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(EditorController.forKeyWindow() === docB.controller)
        try await key("z", keyCode: 6, flags: .command)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(docA.text.contains("EDITED"), "⌘Z in b.md must not undo a.md")
        XCTAssertEqual(docB.text, "Beta text\n")

        store.activate(docA.id)
        try await Task.sleep(for: .milliseconds(300))
        let back = try await js(docA, "return document.querySelector('.vditor-ir .vditor-reset').scrollTop") as! Double
        XCTAssertEqual(back, scroll, accuracy: 1, "scroll position of a.md")
        XCTAssertTrue(EditorController.forKeyWindow() === docA.controller)
        try await key("z", keyCode: 6, flags: .command)
        try await waitUntil(5, "a.md undone") { docA.text == long }
        XCTAssertFalse(docA.isDirty, "back to the file's text: clean")
    }

    /// TB-26: zoom is one setting for every tab, hidden ones included.
    func testZoomIsSharedByTabs() async throws {
        let a = try file("a.md", "Alpha\n")
        let b = try file("b.md", "Beta\n")
        wc.open([a])
        let docA = try XCTUnwrap(store.active)
        try await ready(docA)
        wc.open([b])
        let docB = try XCTUnwrap(store.active)
        try await ready(docB)
        UserDefaults.standard.set(1.2, forKey: ZoomPreference.key)
        try await waitUntil(5, "both tabs at 120 %") {
            docA.controller?.webView.pageZoom == 1.2 && docB.controller?.webView.pageZoom == 1.2
        }
    }

    /// TB-33: each tab loads relative images from its own file's folder, also after switching.
    func testRelativeImagesFromEachTabsFolder() async throws {
        let png = try Samples.data("pic.png")
        let a = try file("a.md", "![](pic.png)\n", in: "one")
        let b = try file("b.md", "![](pic.png)\n", in: "two")
        try png.write(to: dir.appending(path: "one/pic.png"))
        try png.write(to: dir.appending(path: "two/pic.png"))
        func imageLoaded(_ doc: OpenDocument) async throws {
            try await waitUntil(10, "image in \(doc.displayName)") {
                let w = try await self.js(doc, "const i = document.querySelector('.vditor-ir img'); return i ? i.naturalWidth : 0") as? Int
                return (w ?? 0) > 0
            }
        }
        wc.open([a])
        let docA = try XCTUnwrap(store.active)
        try await ready(docA)
        try await imageLoaded(docA)
        wc.open([b])
        let docB = try XCTUnwrap(store.active)
        try await ready(docB)
        try await imageLoaded(docB)
        XCTAssertEqual(docA.controller?.schemeHandler.documentDirectory?.standardizedFileURL, a.deletingLastPathComponent().standardizedFileURL)
        XCTAssertEqual(docB.controller?.schemeHandler.documentDirectory?.standardizedFileURL, b.deletingLastPathComponent().standardizedFileURL)
        store.activate(docA.id)
        try await imageLoaded(docA)
    }

    // MARK: Saving and closing (step 3)

    /// ⌘S writes the active tab now; its file on disk gets the edit, the tab becomes clean.
    func testCmdSSavesActiveTab() async throws {
        try requireForeground()
        OpenDocument.autosaveDelay = .seconds(60)
        let a = try file("a.md", "Alpha\n")
        wc.open([a])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        try await type(" saved", after: "Alpha", in: doc)
        try await waitUntil(5, "edit") { doc.isDirty }
        try await key("s", keyCode: 1, flags: .command)
        try await waitUntil(5, "written") { !doc.isDirty }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "Alpha saved\n")
        XCTAssertEqual(fake.calls, [])
    }

    /// TB-31: the red button closes tab by tab; a clean file tab goes, Untitled with text asks, Cancel keeps it and the window.
    func testRedButtonAsksForUntitledAndCancelKeepsWindow() async throws {
        let a = try file("a.md", "Alpha\n")
        wc.open([a])
        let untitled = store.newUntitled()
        untitled.editorChanged("Draft\n")
        fake.closeChoice = .cancel
        wc.window?.performClose(nil)
        try await waitUntil(5, "question asked") { self.fake.calls.contains("askToSave Untitled") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.tabs.map(\.displayName), ["Untitled"], "a.md closed, Untitled kept")
        XCTAssertEqual(wc.window?.isVisible, true)
        XCTAssertEqual(store.activeID, untitled.id, "the question is about the visible tab")
    }

    /// TB-31: the red button writes a dirty file tab without a question, then really closes the window.
    func testRedButtonWritesDirtyFileTabWithoutQuestion() async throws {
        OpenDocument.autosaveDelay = .seconds(60)
        let a = try file("a.md", "Alpha\n")
        wc.open([a])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        try await type(" red", after: "Alpha", in: doc)
        try await waitUntil(5, "edit") { doc.isDirty }
        fake.closeChoice = .cancel // would keep the tab if it were asked
        let window = try XCTUnwrap(wc.window)
        let closedWindow = XCTNSNotificationExpectation(name: NSWindow.willCloseNotification, object: window)
        window.performClose(nil)
        try await waitUntil(5, "tab closed") { self.store.tabs.isEmpty }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "Alpha red\n")
        XCTAssertEqual(fake.calls, [])
        await fulfillment(of: [closedWindow], timeout: 5)
        XCTAssertFalse(window.isVisible)
    }

    /// TB-11 (changed by Stas 05.11): ⌘W on a dirty file tab writes the file and closes the tab, no question.
    func testCmdWWritesDirtyFileTabWithoutQuestion() async throws {
        try requireForeground()
        OpenDocument.autosaveDelay = .seconds(60)
        let a = try file("a.md", "Alpha\n")
        wc.open([a])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        try await type(" closed", after: "Alpha", in: doc)
        try await waitUntil(5, "edit") { doc.isDirty }
        fake.closeChoice = .cancel
        try await key("w", keyCode: 13, flags: .command)
        try await waitUntil(5, "tab closed") { self.store.tabs.isEmpty }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "Alpha closed\n")
        XCTAssertEqual(fake.calls, [])
    }

    /// A file over 2000 lines posts typed text 800 ms late. ⌘W right after typing still writes those keys:
    /// the close reads the page's text before it writes (flush).
    func testCmdWRightAfterTypingInBigFileWritesTheKeys() async throws {
        try requireForeground()
        OpenDocument.autosaveDelay = .seconds(60)
        let lines = (1...2100).map { "Line \($0)" }.joined(separator: "\n")
        let a = try file("big.md", "Alpha\n\n" + lines + "\n")
        wc.open([a])
        let doc = try XCTUnwrap(store.active)
        try await ready(doc)
        try await type(" typed", after: "Alpha", in: doc)
        XCTAssertFalse(doc.isDirty, "precondition: the page has not posted the keys yet")
        try await key("w", keyCode: 13, flags: .command)
        try await waitUntil(5, "tab closed") { self.store.tabs.isEmpty }
        let saved = try String(contentsOf: a, encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("Alpha typed\n"), String(saved.prefix(40)))
        XCTAssertTrue(saved.hasSuffix("Line 2100\n"))
        XCTAssertEqual(fake.calls, [])
    }
}
