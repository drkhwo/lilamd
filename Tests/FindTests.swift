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

        harness!.controller.clearFind()
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
        let editorValueBeforeFind = try await harness!.js("return mdeditor.getValue()") as? String
        let initialEditorValue = try XCTUnwrap(editorValueBeforeFind)

        _ = await controller.find("find")
        _ = await controller.findNext()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(document.data(), original)
        XCTAssertFalse(document.isDirty)
        controller.undo()
        try await waitUntil(3, "undo leaves find untouched") {
            try await self.harness!.js("return mdeditor.getValue()") as? String == initialEditorValue
        }
        XCTAssertFalse(document.isDirty)
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
        harness!.controller.setMode(.visual)
        try await waitUntil(20, "Visual mode ready") {
            try await self.harness!.js("return mdeditor.instance && mdeditor.instance.getCurrentMode()") as? String == "ir"
        }
        try await waitUntil(5, "Visual mode search restored") { document.findCount == 2 }
        XCTAssertEqual(document.findQuery, "release")
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
