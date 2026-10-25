import XCTest
@testable import MDEditor

final class SourcePreserverTests: XCTestCase {
    func testUnchangedReturnsOriginal() {
        let p = SourcePreserver(original: "* a\n* b\n", baseline: "* a\n* b\n")
        XCTAssertEqual(p.merge(current: "* a\n* b\n"), "* a\n* b\n")
    }

    func testNormalizedUntouchedBlocksKeepOriginalText() {
        let original = "* one\n* two\n\n|a|b|\n|-|-|\n|1|2|\n\nPara here.\n"
        let baseline = "* one\n* two\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nPara here.\n"
        let current = "* one\n* two\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nPara changed.\n"
        let p = SourcePreserver(original: original, baseline: baseline)
        XCTAssertEqual(p.merge(current: current), "* one\n* two\n\n|a|b|\n|-|-|\n|1|2|\n\nPara changed.\n")
    }

    func testCRLFKeptForUntouchedAndNewLines() {
        let original = "# T\r\n\r\nA line.\r\n\r\nB line.\r\n"
        let baseline = "# T\n\nA line.\n\nB line.\n"
        let p = SourcePreserver(original: original, baseline: baseline)
        XCTAssertEqual(p.merge(current: "# T\n\nA line!\n\nB line.\n"), "# T\r\n\r\nA line!\r\n\r\nB line.\r\n")
        XCTAssertEqual(p.merge(current: "# T\n\nA line.\n\nB line.\n\nC\n"), "# T\r\n\r\nA line.\r\n\r\nB line.\r\n\r\nC\r\n")
    }

    func testMissingTrailingNewlineKept() {
        let p = SourcePreserver(original: "a\n\nlast", baseline: "a\n\nlast\n")
        XCTAssertEqual(p.merge(current: "a\n\nlast\n"), "a\n\nlast")
        XCTAssertEqual(p.merge(current: "b\n\nlast\n"), "b\n\nlast")
        XCTAssertEqual(p.merge(current: "a\n\nlast\n\nmore\n"), "a\n\nlast\n\nmore\n")
    }

    func testDeletionAndInsertion() {
        let o = "x\n\n* p\n* q\n\nend\n"
        let b = "x\n\n- p\n- q\n\nend\n"
        let p = SourcePreserver(original: o, baseline: b)
        XCTAssertEqual(p.merge(current: "x\n\nend\n"), "x\n\nend\n")
        XCTAssertEqual(p.merge(current: "new\n\nx\n\n- p\n- q\n\nend\n"), "new\n\nx\n\n* p\n* q\n\nend\n")
    }

    func testLuteTaskNormalizationIsUndoneOnToggle() {
        let o = "- [ ] open task\n- [x] done task\n"
        let b = "- [ ]  open task\n- [X]  done task\n"
        let p = SourcePreserver(original: o, baseline: b)
        XCTAssertEqual(p.merge(current: "- [X]  open task\n- [X]  done task\n"), "- [x] open task\n- [x] done task\n")
    }

    func testPatchLineKeepsOriginalSpellingAroundEdit() {
        XCTAssertEqual(SourcePreserver.patchLine(original: "|a|b|", baseline: "| a | b |", current: "| a | bc |"), "|a|bc|")
        XCTAssertEqual(SourcePreserver.patchLine(original: "same", baseline: "same", current: "same!"), "same!")
    }
}
