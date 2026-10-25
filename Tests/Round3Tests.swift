import AppKit
import XCTest
@testable import MDEditor

/// Round 3 must_fix: the tester's exact scenarios, through native key events.
@MainActor
final class Round3Tests: XCTestCase {
    var h: EditorHarness?

    override func tearDown() async throws {
        h?.close()
        h = nil
    }

    static let tableFirst = "| Name  | Value | Note        |\n|-------|------:|:-----------:|\n| alpha | 1     | first row   |\n| beta  | 22    | second row  |\n\nA paragraph after the table.\n"
    static let upArrow = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)
    static let leftArrow = String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)

    /// Open (caret lands in the first cell), Cmd+Up, type "7": the 7 goes into the first cell, no line above.
    func testTableFirstCmdUpThenTypeStaysInFirstCell() async throws {
        try await typeAfter(key: Self.upArrow, keyCode: 126, flags: [.command, .numericPad, .function])
    }

    func testTableFirstArrowUpThenTypeStaysInFirstCell() async throws {
        try await typeAfter(key: Self.upArrow, keyCode: 126, flags: [.numericPad, .function])
    }

    func testTableFirstArrowLeftThenTypeStaysInFirstCell() async throws {
        try await typeAfter(key: Self.leftArrow, keyCode: 123, flags: [.numericPad, .function])
    }

    private func typeAfter(key: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) async throws {
        let original = Self.tableFirst
        let h = try await EditorHarness(text: original)
        self.h = h
        try await h.focus()
        try await Task.sleep(for: .milliseconds(300))
        try await h.key(key, keyCode: keyCode, flags: flags)
        try await Task.sleep(for: .milliseconds(300))
        try await h.key("7", keyCode: 26)
        try await h.waitForText { $0 != original }
        try await Task.sleep(for: .milliseconds(500))
        let diff = changedLineRange(original, h.controller.text)
        XCTAssertTrue(h.controller.text.hasPrefix("| "), "text before the table: \(h.controller.text.prefix(40).debugDescription)")
        XCTAssertEqual(diff.old, ["| Name  | Value | Note        |"])
        XCTAssertEqual(diff.new.count, 1)
        XCTAssertTrue(diff.new.first?.contains("7") == true, "\(diff.new)")
        let above = try await h.js("const t = mdeditor.root().querySelector('table'); return t.previousElementSibling ? t.previousElementSibling.outerHTML : null") as? String
        XCTAssertNil(above, "nothing is rendered above the table")
    }

    /// Cmd+= in a table that follows a blank line adds only the new row (no second blank line above).
    func testCmdEqualsAddsOnlyTheRow() async throws {
        for prefix in ["Intro line.\n\n", "## Table\n\n"] {
            let original = prefix + "| Name  | Value | Note        |\n|-------|------:|:-----------:|\n| alpha | 1     | first row   |\n| beta  | 22    | second row  |\n\nA paragraph after the table.\n"
            let h = try await EditorHarness(text: original)
            self.h = h
            try await h.focus()
            try await h.select("alpha", collapseToEnd: true)
            try await h.key("=", keyCode: 24, flags: .command)
            try await h.waitForText { $0 != original }
            try await Task.sleep(for: .milliseconds(500))
            let diff = changedLineRange(original, h.controller.text)
            XCTAssertEqual(diff.old, [], prefix)
            XCTAssertEqual(diff.new.count, 1, "\(prefix.debugDescription): \(diff.new)")
            XCTAssertTrue(diff.new.first?.hasPrefix("|") == true, "\(diff.new)")
            h.close()
            self.h = nil
        }
    }
}
