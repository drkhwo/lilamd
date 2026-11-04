import AppKit
import XCTest
@testable import MDEditor

@MainActor
final class Round4Tests: XCTestCase {
    var h: EditorHarness?

    override func tearDown() async throws {
        h?.close()
        h = nil
    }

    func testT1_visualTableCellsWrap() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let styles = try await h!.js("""
        const td = document.querySelector('.vditor-ir table td');
        const th = document.querySelector('.vditor-ir table th');
        const pick = e => { const s = getComputedStyle(e); return { whiteSpace: s.whiteSpace, overflowWrap: s.overflowWrap, minWidth: s.minWidth }; };
        return { td: pick(td), th: pick(th), em: parseFloat(getComputedStyle(td).fontSize) * 4 };
        """) as! [String: Any]
        for key in ["td", "th"] {
            let cell = styles[key] as! [String: String]
            XCTAssertEqual(cell["whiteSpace"], "normal")
            XCTAssertEqual(cell["overflowWrap"], "anywhere")
            XCTAssertEqual(Double(cell["minWidth"]!.replacingOccurrences(of: "px", with: ""))!, (styles["em"] as! Double), accuracy: 1)
        }
    }

    func testT2_longParagraphFitsEditor() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let sizes = try await h!.js("const t = document.querySelector('.vditor-ir table'); const r = document.querySelector('.vditor-ir'); return {sw:t.scrollWidth, cw:t.clientWidth, rw:r.clientWidth}") as! [String: Double]
        XCTAssertLessThanOrEqual(sizes["sw"]!, sizes["cw"]!)
        XCTAssertLessThanOrEqual(sizes["sw"]!, sizes["rw"]!)
    }

    /// Cells of one row stretch to the same height, so compare the body row with the one-line header row.
    /// Old behaviour (`white-space: nowrap`): the body row is one line tall, same as the header.
    func testT3_longCellIsTallerThanHeaderRow() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let m = try await h!.js("const t=document.querySelector('.vditor-ir table'); return {head:t.rows[0].cells[1].getBoundingClientRect().height, body:t.rows[1].cells[1].getBoundingClientRect().height}") as! [String: Double]
        XCTAssertGreaterThan(m["body"]!, m["head"]! * 3, "400-char paragraph must wrap to several lines: \(m)")
    }

    func testT4_urlBreaksInsideCell() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let r = try await h!.js("const t=document.querySelectorAll('.vditor-ir table')[1]; return {sw:t.scrollWidth,cw:t.clientWidth,head:t.rows[0].cells[1].getBoundingClientRect().height,cell:t.rows[1].cells[1].getBoundingClientRect().height}") as! [String: Double]
        XCTAssertLessThanOrEqual(r["sw"]!, r["cw"]!, "no sideways scroll for a 120-char URL: \(r)")
        XCTAssertGreaterThan(r["cell"]!, r["head"]! * 1.5, "URL must break into several lines: \(r)")
    }

    func testT5_wideTableRetainsFallbackScrolling() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let values = try await h!.js("""
        const t=document.querySelectorAll('.vditor-ir table')[2];
        const s=getComputedStyle(t);
        const em=parseFloat(getComputedStyle(t.rows[0].cells[0]).fontSize)*4;
        return {display:s.display,overflowX:s.overflowX,scrollWidth:t.scrollWidth,clientWidth:t.clientWidth,
          em,widths:Array.from(t.rows[0].cells).map(cell=>cell.getBoundingClientRect().width)};
        """) as! [String: Any]
        XCTAssertEqual(values["display"] as? String, "block")
        XCTAssertEqual(values["overflowX"] as? String, "auto")
        XCTAssertGreaterThan(values["scrollWidth"] as! Double, values["clientWidth"] as! Double)
        let minWidth = values["em"] as! Double
        for width in values["widths"] as! [Double] {
            XCTAssertGreaterThanOrEqual(width + 1, minWidth)
        }
    }

    func testT6_sourceModeRemainsMonospacedAndUnchanged() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"), mode: .source)
        let values = try await h!.js("const s=document.querySelector('.vditor-sv'); const c=getComputedStyle(s); const td=s.querySelector('td'); return {font:c.fontFamily,hasCell:!!td, cellWrap:td ? getComputedStyle(td).whiteSpace : ''}") as! [String: Any]
        let font = values["font"] as! String
        XCTAssertTrue(font.lowercased().contains("mono") || font.contains("Menlo"))
        XCTAssertEqual(values["hasCell"] as? Bool, false)
        XCTAssertNotEqual(values["cellWrap"] as? String, "normal")
    }

    func testT7_longCellEditChangesOnlyItsSourceRow() async throws {
        let original = try Samples.text("wide-table.md")
        h = try await EditorHarness(text: original)
        try await h!.focus()
        try await h!.select("approximately four hundred characters", collapseToEnd: true)
        try await h!.insertText(" exactly four hundred characters")
        try await h!.waitForText { $0.contains("exactly four hundred characters") }
        let diff = changedLineRange(original, h!.controller.text)
        XCTAssertEqual(diff.old.count, 1)
        XCTAssertEqual(diff.new.count, 1)
    }

    func testT8_loadingWideTablePreservesSource() async throws {
        let original = try Samples.text("wide-table.md")
        h = try await EditorHarness(text: original)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(h!.changes.isEmpty)
        XCTAssertEqual(h!.controller.text, original)
    }

    func testT9_longFirstCellKeepsCaretAtTableStart() async throws {
        let original = "| \(String(repeating: "long first cell text ", count: 20)) | Value |\n|---|---|\n| a | b |\n"
        h = try await EditorHarness(text: original)
        try await h!.focus()
        try await Task.sleep(for: .milliseconds(300))
        try await h!.key(String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), keyCode: 126, flags: [.command, .numericPad, .function])
        try await Task.sleep(for: .milliseconds(300))
        try await h!.key("7", keyCode: 26)
        try await h!.waitForText { $0 != original }
        try await Task.sleep(for: .milliseconds(500))
        let diff = changedLineRange(original, h!.controller.text)
        XCTAssertTrue(h!.controller.text.hasPrefix("| "), "text before the table: \(h!.controller.text.prefix(40).debugDescription)")
        XCTAssertEqual(diff.old.map(String.init), [original.components(separatedBy: "\n")[0]])
        XCTAssertEqual(diff.new.count, 1)
        XCTAssertTrue(diff.new.first?.components(separatedBy: "|").dropFirst().first?.contains("7") == true, "first cell: \(diff.new)")
        let above = try await h!.js("const t=mdeditor.root().querySelector('table'); return !!t.previousElementSibling") as? Bool
        XCTAssertEqual(above, false, "nothing is rendered above the table")
    }
}
