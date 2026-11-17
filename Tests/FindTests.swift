import AppKit
import XCTest
@testable import MDEditor

@MainActor
final class FindTests: XCTestCase {
    private var harness: EditorHarness?

    override func tearDown() async throws {
        harness?.close()
        harness = nil
    }

    func testFindCountsMatchesWrapsAndClearsHighlights() async throws {
        harness = try await EditorHarness(text: "Release the release. RELEASE again.\n")
        let first = await harness!.controller.find("release")
        XCTAssertEqual(first, EditorFindResult(count: 3, index: 0))
        let second = await harness!.controller.findNext()
        let third = await harness!.controller.findNext()
        let wrapped = await harness!.controller.findNext()
        let previous = await harness!.controller.findPrevious()
        XCTAssertEqual(second, EditorFindResult(count: 3, index: 1))
        XCTAssertEqual(third, EditorFindResult(count: 3, index: 2))
        XCTAssertEqual(wrapped, EditorFindResult(count: 3, index: 0))
        XCTAssertEqual(previous, EditorFindResult(count: 3, index: 2))
        let highlighted = try await harness!.js("return CSS.highlights.has('mdedit-find') && CSS.highlights.has('mdedit-find-current')") as? Bool
        XCTAssertEqual(highlighted, true)

        await harness!.controller.closeFind()
        try await waitUntil(3, "find highlights cleared") {
            try await self.harness!.js("return !CSS.highlights.has('mdedit-find') && !CSS.highlights.has('mdedit-find-current')") as? Bool == true
        }
    }

    func testFindDoesNotChangeFileDirtyStateOrUndoHistory() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "find.md")
        let original = Data("Find me. Find me again.\r\n".utf8)
        try original.write(to: url)
        let document = try OpenDocument(contentsOf: url)
        let controller = document.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        let initialEditorValueValue = try await harness!.js("return mdeditor.getValue()") as? String
        let initialEditorValue = try XCTUnwrap(initialEditorValueValue)
        try await harness!.select("again", collapseToEnd: true)
        try await harness!.insertText(" find")
        try await harness!.waitForText { $0.contains("again find") }
        XCTAssertTrue(document.isDirty)
        await document.openFind()
        document.setFindQuery("find")
        try await waitUntil(5, "find open after the edit") { document.findCount == 3 }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(document.isDirty)
        controller.undo()
        try await waitUntil(3, "undo leaves find untouched") {
            try await self.harness!.js("return mdeditor.getValue()") as? String == initialEditorValue
        }
        try await waitUntil(5, "undo recounts the original match count") { document.findCount == 2 }
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.data(), original)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFindWorksInVisualAndSourceModes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-modes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "modes.md")
        try Data("# Release\n\nrelease notes\n".utf8).write(to: url)
        let document = try OpenDocument(contentsOf: url)
        let controller = document.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        await document.openFind()
        document.setFindQuery("release")
        try await waitUntil(5, "Visual mode matches") { document.findCount == 2 }
        XCTAssertEqual(document.findIndex, 0)

        harness!.controller.setMode(.source)
        try await waitUntil(20, "Source mode ready") {
            try await self.harness!.js("return mdeditor.instance && mdeditor.instance.getCurrentMode()") as? String == "sv"
        }
        try await waitUntil(5, "Source mode search rerun") { document.findCount == 2 }
        let sourceRanges = try await harness!.js("return CSS.highlights.get('mdedit-find')?.size || 0") as? Int
        XCTAssertGreaterThan(sourceRanges ?? 0, 0, "Source mode must use DOM highlight ranges")
        harness!.controller.setMode(.visual)
        try await waitUntil(20, "Visual mode ready") {
            try await self.harness!.js("return mdeditor.instance && mdeditor.instance.getCurrentMode()") as? String == "ir"
        }
        try await waitUntil(5, "Visual mode search restored") { document.findCount == 2 }
        XCTAssertEqual(document.findQuery, "release")
    }

    func testFindCrossesInlineFormattingAndCoversCodeAndLinks() async throws {
        harness = try await EditorHarness(text: "the **release** notes and `inline code` plus [link words](u)\n")
        let acrossStart = await harness!.controller.find("the release")
        let acrossEnd = await harness!.controller.find("release notes")
        let code = await harness!.controller.find("inline code")
        let link = await harness!.controller.find("link words")
        XCTAssertEqual(acrossStart, EditorFindResult(count: 1, index: 0))
        XCTAssertEqual(acrossEnd, EditorFindResult(count: 1, index: 0))
        XCTAssertEqual(code, EditorFindResult(count: 1, index: 0))
        XCTAssertEqual(link, EditorFindResult(count: 1, index: 0))
    }

    func testMissingHighlightAPIUsesSelectionWithoutChangingFocus() async throws {
        harness = try await EditorHarness(text: "Find the fallback match.\n")
        let result = try await harness!.js("""
          const descriptor = Object.getOwnPropertyDescriptor(CSS, 'highlights');
          Object.defineProperty(CSS, 'highlights', { configurable: true, value: undefined });
          try {
            const active = document.activeElement;
            const found = mdeditor.find('fallback', 0);
            return { found, selected: getSelection().toString(), sameFocus: document.activeElement === active };
          } finally {
            if (descriptor) Object.defineProperty(CSS, 'highlights', descriptor);
          }
        """) as? [String: Any]
        XCTAssertEqual((result?["found"] as? [String: Int])?["count"], 1)
        XCTAssertEqual(result?["selected"] as? String, "fallback")
        XCTAssertEqual(result?["sameFocus"] as? Bool, true)
    }

    func testFindPerformanceOnThreeThousandLines() async throws {
        let text = String(repeating: "e\n", count: 3000)
        harness = try await EditorHarness(text: text)
        let result = try await harness!.js("""
          const start = performance.now();
          const result = mdeditor.find('e', 0);
          return { ...result, elapsed: performance.now() - start };
        """) as? [String: Double]
        XCTAssertEqual(result?["count"], 3000)
        XCTAssertLessThan(result?["elapsed"] ?? .infinity, 1000)
    }

    func testEditingRecomputesOpenFindCount() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "edit.md")
        try Data("Release notes.\n".utf8).write(to: url)
        let document = try OpenDocument(contentsOf: url)
        let controller = document.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        await document.openFind()
        document.setFindQuery("release")
        try await waitUntil(5, "initial matches") { document.findCount == 1 }

        try await harness!.select("Release", collapseToEnd: true)
        try await harness!.insertText(" release")
        try await harness!.waitForText { $0.contains("Release release") }
        try await waitUntil(5, "updated find count") { document.findCount == 2 }
        XCTAssertTrue(document.isDirty)
    }

    func testFindStateSurvivesTabSwitch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false
        let file = folder.appending(path: "first.md")
        try Data("persist persist".utf8).write(to: file)
        let first = try store.open(file)
        let second = store.newUntitled()
        let controller = first.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        await first.openFind()
        first.setFindQuery("persist")
        try await waitUntil(5, "two find matches") { first.findCount == 2 }
        first.findNext()
        try await waitUntil(5, "second find match") { first.findIndex == 1 }
        store.activate(second.id)
        store.activate(first.id)

        XCTAssertTrue(first.isFindOpen)
        XCTAssertEqual(first.findQuery, "persist")
        XCTAssertEqual(first.findIndex, 1)
        XCTAssertFalse(second.isFindOpen)
        let webFindState = try await harness!.js("""
          const all = CSS.highlights.get('mdedit-find');
          const current = CSS.highlights.get('mdedit-find-current');
          return { count: all?.size || 0, currentCount: current?.size || 0,
                   currentOffset: current?.values().next().value?.startOffset ?? -1 };
        """) as? [String: Int]
        XCTAssertEqual(webFindState?["count"], 2)
        XCTAssertEqual(webFindState?["currentCount"], 1)
        XCTAssertEqual(webFindState?["currentOffset"], 8)
    }

    func testCloseFindRestoresWebViewFocusAndSelectsCurrentMatch() async throws {
        try requireForeground()
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "focus.md")
        try Data("first match, second match\n".utf8).write(to: url)
        let document = try OpenDocument(contentsOf: url)
        let controller = document.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        await document.openFind()
        document.setFindQuery("match")
        try await waitUntil(5, "current match selected for close") { document.findCount == 2 }
        document.findNext()
        try await waitUntil(5, "second current match") { document.findIndex == 1 }
        document.closeFind()
        try await waitUntil(5, "web view is first responder") {
            harness!.window.firstResponder === controller.webView || harness!.window.firstResponder?.nextResponder === controller.webView
        }
        let selected = try await controller.selectionText()
        XCTAssertEqual(selected, "match")
    }

    func testOpenFindPrefillsDocumentSelectionEvenWhenQueryAlreadyExists() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-prefill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "prefill.md")
        try Data("alpha beta\n".utf8).write(to: url)
        let document = try OpenDocument(contentsOf: url)
        let controller = document.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        document.setFindQuery("old query")
        try await harness!.select("beta")
        await document.openFind()
        XCTAssertEqual(document.findQuery, "beta")
    }

    func testEditDrivenRecountDoesNotScroll() async throws {
        let text = "needle\n" + String(repeating: "middle\n", count: 500) + "tail\n"
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "scroll.md")
        try Data(text.utf8).write(to: url)
        let document = try OpenDocument(contentsOf: url)
        let controller = document.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        await document.openFind()
        document.setFindQuery("needle")
        try await waitUntil(5, "initial top match") { document.findCount == 1 }
        try await harness!.js("const root = mdeditor.root(); root.scrollTop = root.scrollHeight;")
        try await harness!.select("tail", collapseToEnd: true)
        let before = try await harness!.js("return mdeditor.root().scrollTop") as? Double
        try await harness!.insertText(" needle")
        try await waitUntil(5, "edit-driven match recount") { document.findCount == 2 }
        try await Task.sleep(for: .milliseconds(250))
        let after = try await harness!.js("return mdeditor.root().scrollTop") as? Double
        XCTAssertEqual(try XCTUnwrap(after), try XCTUnwrap(before), accuracy: 1)
    }

    func testShiftCommandGDoesNotModifyTableCell() async throws {
        try requireForeground()
        let original = "| A | B |\n|---|---|\n| alpha | beta |\n"
        let folder = FileManager.default.temporaryDirectory.appending(path: "find-table-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "table.md")
        try Data(original.utf8).write(to: url)
        let document = try OpenDocument(contentsOf: url)
        let controller = document.makeController(mode: .visual, zoom: 1)
        harness = try await EditorHarness(controller: controller)
        try await harness!.focus()
        try await harness!.select("alpha", collapseToEnd: true)
        try await harness!.key("G", keyCode: 5, flags: [.command, .shift])
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(harness!.controller.text, original)
        XCTAssertTrue(harness!.changes.isEmpty)
        XCTAssertFalse(document.isDirty)
    }

    func testFindSkipsHiddenText() async throws {
        harness = try await EditorHarness(text: "visible word\n")
        let result = try await harness!.js("""
          const root = mdeditor.root();
          const hidden = document.createElement('span');
          hidden.style.display = 'none'; hidden.textContent = ' hiddenword'; root.append(hidden);
          return mdeditor.find('hiddenword', 0);
        """) as? [String: Int]
        XCTAssertEqual(result?["count"], 0)
    }

    func testFindOnStartScreenFocusesHistorySearch() async throws {
        try requireForeground()
        let root = FileManager.default.temporaryDirectory.appending(path: "find-start-\(UUID().uuidString)")
        let url = root.appending(path: "history.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = HistoryStore(storageURL: url, systemRecentsSink: { _ in })
        let sample = root.appending(path: "sample.md")
        try Data("text".utf8).write(to: sample)
        history.noteOpen(sample)
        let store = TabStore(prompter: FakePrompter(), historyStore: history)
        let windowController = MainWindowController(store: store, historyStore: history)
        defer {
            windowController.window?.close()
            try? FileManager.default.removeItem(at: root)
        }
        windowController.show()
        let window = try XCTUnwrap(windowController.window)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "f", charactersIgnoringModifiers: "f",
                                         isARepeat: false, keyCode: 3)!
            NSApp.sendEvent(event)
        }
        try await waitUntil(3, "start-screen search focused") {
            guard let fieldEditor = window.firstResponder as? NSTextView else { return false }
            return fieldEditor.delegate is NSTextField
        }
    }
}
