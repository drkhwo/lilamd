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

    /// Randomized: a fake line-wise "engine" (`* ` -> `- `, `[X]`), random line inserts/deletes/edits.
    /// Re-normalizing the merged text must give exactly what the editor holds, and nothing may crash.
    func testRandomEditsRoundTrip() {
        func norm(_ line: Substring) -> String {
            var l = String(line)
            if l.hasPrefix("* ") { l = "- " + l.dropFirst(2) }
            return l.replacingOccurrences(of: "|-|", with: "| - |")
        }
        let pool = ["* item", "* other", "", "text line", "|-|", "## head", "```", "code", "- [ ] task", "plain"]
        var rng = SystemRandomNumberGenerator()
        for round in 0..<500 {
            let n = Int.random(in: 1...20, using: &rng)
            let oLines = (0..<n).map { _ in pool.randomElement(using: &rng)! }
            let crlf = round % 3 == 0 // a one-line file without a newline has no line ending to keep
            let original = oLines.joined(separator: crlf ? "\r\n" : "\n") + (round % 2 == 0 ? (crlf ? "\r\n" : "\n") : "")
            let bLines = SourcePreserver.editorText(for: original).split(separator: "\n", omittingEmptySubsequences: false).map(norm)
            let baseline = bLines.joined(separator: "\n")
            var cLines = bLines
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: cLines.insert(norm(Substring(pool.randomElement(using: &rng)!)), at: Int.random(in: 0...cLines.count, using: &rng))
                case 1: if cLines.count > 1 { cLines.remove(at: Int.random(in: 0..<cLines.count, using: &rng)) }
                default: let i = Int.random(in: 0..<cLines.count, using: &rng); cLines[i] += " edit"
                }
            }
            let current = cLines.joined(separator: "\n")
            let p = SourcePreserver(original: original, baseline: baseline)
            XCTAssertEqual(p.merge(current: baseline), original)
            let merged = p.merge(current: current)
            let renormalized = SourcePreserver.editorText(for: merged).split(separator: "\n", omittingEmptySubsequences: false).map(norm).joined(separator: "\n")
            XCTAssertEqual(renormalized, current, "round \(round): original \(original.debugDescription) current \(current.debugDescription) merged \(merged.debugDescription)")
            if original.contains("\r\n") { XCTAssertFalse(merged.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF kept: \(original.debugDescription) -> \(current.debugDescription) = \(merged.debugDescription)") }
        }
    }
}
