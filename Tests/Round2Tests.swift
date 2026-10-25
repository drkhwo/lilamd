import AppKit
import XCTest
@testable import MDEditor

/// Round 2 should_fix items.
@MainActor
final class Round2Tests: XCTestCase {
    var h: EditorHarness?

    override func tearDown() async throws {
        h?.close()
        h = nil
    }

    // 1. Conflict dialog: Return and Space keep the user's edits.
    func testConflictAlertSafeChoiceIsDefaultAndFocused() async throws {
        let alert = FileWatcher.makeConflictAlert(fileName: "x.md")
        XCTAssertEqual(alert.buttons.map(\.title), ["Keep My Version", "Reload from Disk"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        // Return: the window's default button (key equivalent "\r") is Keep. A background test host
        // cannot deliver Return to a sheet (NSButton key equivalents need a key window), so this part is
        // structural; Space goes to the focused button and is pressed for real below.
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
        let response = try await present(FileWatcher.makeConflictAlert(fileName: "x.md"), pressing: " ", keyCode: 49)
        XCTAssertEqual(response, FileWatcher.keepResponse, "Space must keep the edits")
    }

    private func present(_ alert: NSAlert, pressing chars: String, keyCode: UInt16) async throws -> NSApplication.ModalResponse? {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var response: NSApplication.ModalResponse?
        alert.beginSheetModal(for: window) { response = $0 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(window.attachedSheet === alert.window)
        XCTAssertTrue(alert.window.firstResponder === alert.buttons[0], "focus is on Keep My Version, not \(String(describing: alert.window.firstResponder))")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: alert.window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
            alert.window.sendEvent(e)
        }
        try await waitUntil(3, "sheet answered") { response != nil }
        return response
    }

    // 2. Default window size.
    func testDefaultWindowSizeFitsScreen() {
        let size = MDEditorApp.defaultWindowSize
        let visible = NSScreen.main!.visibleFrame.size
        XCTAssertLessThanOrEqual(size.width, visible.width)
        XCTAssertLessThanOrEqual(size.height, visible.height)
        if visible.width >= 1140, visible.height >= 840 { XCTAssertEqual(size, CGSize(width: 1100, height: 800)) }
    }

    // 3. Document starting with a table: no caret line above it, nothing added to the file.
    func testDocumentStartingWithTableHasNoPhantomLineAbove() async throws {
        let original = "| Name | Value |\n|------|-------|\n| a    | 1     |\n\nAfter.\n"
        let h = try await EditorHarness(text: original)
        self.h = h
        try await h.focus()
        try await Task.sleep(for: .milliseconds(200))
        let where0 = try await caretPlace(h)
        XCTAssertEqual(where0, "TH", "caret after opening")
        try await h.select("After.", collapseToEnd: true)
        try await h.key(String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), keyCode: 126, flags: [.command, .numericPad, .function])
        try await Task.sleep(for: .milliseconds(200))
        let where1 = try await caretPlace(h)
        XCTAssertEqual(where1, "TH", "caret after Cmd+Up")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(h.controller.text, original)
        XCTAssertTrue(h.changes.isEmpty)
        // Typing there edits the first cell, it does not create a line above the table.
        try await h.insertText("7")
        try await h.waitForText { $0 != original }
        XCTAssertTrue(h.controller.text.hasPrefix("| "), h.controller.text)
        let diff = changedLineRange(original, h.controller.text)
        XCTAssertEqual(diff.old, ["| Name | Value |"])
        XCTAssertEqual(diff.new.count, 1)
    }

    private func caretPlace(_ h: EditorHarness) async throws -> String? {
        try await h.js("""
        const r = getSelection().getRangeAt(0); const n = r.startContainer;
        if (n === mdeditor.root()) return 'ROOT';
        const el = n.nodeType === 3 ? n.parentElement : n; const c = el.closest('th, td, p');
        return c ? c.tagName : el.tagName;
        """) as? String
    }

    // 5. No grey H1/H2 labels next to headings.
    func testNoHeadingLabels() async throws {
        let h = try await EditorHarness(text: "# One\n\n## Two\n\ntext\n")
        self.h = h
        let r = try await h.js("return [...mdeditor.root().querySelectorAll('h1, h2')].map(e => getComputedStyle(e, '::before').content)") as? [String]
        XCTAssertEqual(r, ["none", "none"])
    }
}
