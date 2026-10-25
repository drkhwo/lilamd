import Foundation

/// Keeps the original text of blocks the user did not touch.
///
/// Vditor/Lute returns a *normalized* Markdown (`getValue()`), so feeding it back to the file would
/// rewrite list markers, table rules, escapes and so on. The preserver remembers
/// - `original`: the document text given to the editor (exact file characters, CRLF allowed),
/// - `baseline`: what the editor returned for it before any edit,
/// and for every later editor value it outputs the original lines wherever the editor value still
/// equals the baseline, and the editor's (normalized) lines only in the regions that actually changed.
struct SourcePreserver {
    let original: String
    let baseline: String

    private let originalLines: [Line]
    private let baselineLines: [Substring]
    /// For every baseline line: index of the identical original line, if aligned.
    private let baselineToOriginal: [Int?]
    let lineEnding: String

    private struct Line {
        let content: Substring   // without the terminator
        let terminator: String?  // "\n", "\r\n" or nil for the last line
    }

    init(original: String, baseline: String) {
        self.original = original
        self.baseline = baseline
        let lines = Self.splitKeepingTerminators(original)
        originalLines = lines
        let crlf = lines.filter { $0.terminator == "\r\n" }.count
        let lf = lines.filter { $0.terminator == "\n" }.count
        lineEnding = crlf > lf ? "\r\n" : "\n"
        baselineLines = Self.splitLF(baseline)
        baselineToOriginal = Self.align(from: lines.map(\.content), to: baselineLines)
    }

    /// Text the editor should be given for `original` (LF only; the editor never sees CR).
    static func editorText(for original: String) -> String {
        original.replacingOccurrences(of: "\r\n", with: "\n")
    }

    func merge(current: String) -> String {
        if current == baseline { return original }
        let currentLines = Self.splitLF(current)
        let currentToBaseline = Self.align(from: baselineLines, to: currentLines)
        var baselineToCurrent = [Int?](repeating: nil, count: baselineLines.count)
        for (c, b) in currentToBaseline.enumerated() { if let b { baselineToCurrent[b] = c } }

        // Anchors: baseline lines aligned both to the original and to the current text.
        var anchors: [(o: Int, b: Int, c: Int)] = []
        for b in baselineLines.indices {
            if let o = baselineToOriginal[b], let c = baselineToCurrent[b] {
                anchors.append((o, b, c))
            }
        }

        var out: [(content: Substring, terminator: String?)] = []
        func emitOriginal(_ range: Range<Int>) {
            for i in range { out.append((originalLines[i].content, originalLines[i].terminator)) }
        }
        func emitCurrent(_ range: Range<Int>) {
            for i in range {
                out.append((Self.fixTaskMarker(currentLines[i]), i == currentLines.count - 1 ? nil : lineEnding))
            }
        }

        var prev = (o: -1, b: -1, c: -1)
        for anchor in anchors + [(originalLines.count, baselineLines.count, currentLines.count)] {
            let oRange = (prev.o + 1)..<anchor.o
            let bRange = (prev.b + 1)..<anchor.b
            let cRange = (prev.c + 1)..<anchor.c
            if Array(baselineLines[bRange]) == Array(currentLines[cRange]) {
                emitOriginal(oRange)   // untouched region: keep the file's own text
            } else if let map = regionMap(oRange, bRange) {
                // The engine rewrote this block line by line (maybe adding/removing blank lines), so
                // map lines by position and patch only what the user changed.
                for c in cRange {
                    let isLast = c == currentLines.count - 1
                    if let b = currentToBaseline[c], bRange.contains(b) {
                        // Unchanged line: the original spelling, or nothing if the engine invented it.
                        if let o = map[b - bRange.lowerBound] {
                            out.append((originalLines[o].content, originalLines[o].terminator))
                        } else if isLast || cRange.count != bRange.count {
                            // Keep an engine-added line when lines were inserted/removed around it (it may
                            // now separate new content) and the final "" (= file ends with a newline).
                            out.append((currentLines[c], isLast ? nil : lineEnding))
                        }
                    } else if cRange.count == bRange.count, let o = map[c - cRange.lowerBound] {
                        let b = bRange.lowerBound + (c - cRange.lowerBound)
                        if Self.layoutKey(baselineLines[b]) == Self.layoutKey(currentLines[c]) {
                            // Only re-padded by the engine (e.g. a table whose column widths changed).
                            out.append((originalLines[o].content, isLast ? nil : (originalLines[o].terminator ?? lineEnding)))
                            continue
                        }
                        let patched = Self.patchLine(original: originalLines[o].content, baseline: baselineLines[b], current: currentLines[c])
                        out.append((Substring(patched), isLast ? nil : (originalLines[o].terminator ?? lineEnding)))
                    } else {
                        out.append((Self.fixTaskMarker(currentLines[c]), isLast ? nil : lineEnding))
                    }
                }
            } else {
                emitCurrent(cRange)    // edited region: take the editor's text
            }
            if anchor.o < originalLines.count {
                emitOriginal(anchor.o..<(anchor.o + 1))
            }
            prev = anchor
        }

        var result = ""
        for (i, line) in out.enumerated() {
            result += line.content
            // The last line never gets a terminator: a trailing newline is an empty last line.
            if i < out.count - 1 { result += line.terminator ?? lineEnding }
        }
        return result
    }

    // MARK: - Helpers

    private static func splitLF(_ s: String) -> [Substring] {
        s.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static func splitKeepingTerminators(_ s: String) -> [Line] {
        // Split on "\n" scalars so that "\r\n" (a single Character in Swift) is handled.
        var lines: [Line] = []
        var start = s.unicodeScalars.startIndex
        let scalars = s.unicodeScalars
        var i = start
        while i < scalars.endIndex {
            if scalars[i] == "\n" {
                var end = i
                var term = "\n"
                if end > start, scalars[scalars.index(before: end)] == "\r" {
                    end = scalars.index(before: end)
                    term = "\r\n"
                }
                lines.append(Line(content: Substring(scalars[start..<end]), terminator: term))
                start = scalars.index(after: i)
            }
            i = scalars.index(after: i)
        }
        lines.append(Line(content: Substring(scalars[start..<scalars.endIndex]), terminator: nil))
        return lines
    }

    /// For each baseline line of a region, the original line it is a rewrite of (nil: the engine added
    /// it). Works when both sides have the same number of non-blank lines (blank lines may differ).
    private func regionMap(_ oRange: Range<Int>, _ bRange: Range<Int>) -> [Int?]? {
        if oRange.count == bRange.count { return oRange.map { Optional($0) } }
        let isBlank: (Substring) -> Bool = { $0.allSatisfy { $0 == " " || $0 == "\t" } }
        let oText = oRange.filter { !isBlank(originalLines[$0].content) }
        let bText = bRange.filter { !isBlank(baselineLines[$0]) }
        guard oText.count == bText.count else { return nil }
        var map = [Int?](repeating: nil, count: bRange.count)
        for (o, b) in zip(oText, bText) { map[b - bRange.lowerBound] = o }
        // Blank lines: pair them in order between consecutive text lines; extra ones stay unmapped.
        let oBlank = oRange.filter { isBlank(originalLines[$0].content) }
        var used = Set<Int>()
        for b in bRange where isBlank(baselineLines[b]) {
            let prevText = bText.last { $0 < b }.flatMap { map[$0 - bRange.lowerBound] } ?? (oRange.lowerBound - 1)
            let nextText = bText.first { $0 > b }.flatMap { map[$0 - bRange.lowerBound] } ?? oRange.upperBound
            if let o = oBlank.first(where: { $0 > prevText && $0 < nextText && !used.contains($0) }) {
                map[b - bRange.lowerBound] = o
                used.insert(o)
            }
        }
        return map
    }

    /// A line with spacing and dash runs removed: equal keys mean "same content, different padding".
    static func layoutKey(_ line: Substring) -> String {
        var out = ""
        var lastDash = false
        for ch in line where ch != " " && ch != "\t" {
            if ch == "-" { if lastDash { continue }; lastDash = true } else { lastDash = false }
            out.append(ch)
        }
        return out
    }

    /// A changed current line whose neighbours are unchanged pairs with the baseline line at the same
    /// position (a line edited in place, not inserted or deleted).
    private static func positionalPartner(_ c: Int, cRange: Range<Int>, bRange: Range<Int>, currentToBaseline: [Int?]) -> Int? {
        guard cRange.count == bRange.count else { return nil }
        let b = bRange.lowerBound + (c - cRange.lowerBound)
        return b
    }

    /// Applies the baseline->current change of one line to the original line, keeping the original's
    /// own spelling around the edit (e.g. `* item` stays `* item` when a word is added).
    static func patchLine(original: Substring, baseline: Substring, current: Substring) -> String {
        if original == baseline { return String(fixTaskMarker(current)) }
        let o = Array(original), b = Array(baseline), c = Array(current)
        var p = 0
        while p < b.count, p < c.count, b[p] == c[p] { p += 1 }
        var s = 0
        while s < b.count - p, s < c.count - p, b[b.count - 1 - s] == c[c.count - 1 - s] { s += 1 }
        let bToO = align(from: o, to: b)
        // Nearest aligned characters around the edit (unaligned ones are the engine's own spelling).
        var start = 0
        var i = p - 1
        while i >= 0 { if let m = bToO[i] { start = m + 1; break }; i -= 1 }
        var end = o.count
        var j = b.count - s
        while j < b.count { if let m = bToO[j] { end = m; break }; j += 1 }
        guard start <= end else { return String(fixTaskMarker(current)) }
        var mid = String(c[p..<(c.count - s)])
        // Vditor writes a checked task as "[X]"; keep the usual lowercase form.
        if mid == "X", start > 0, o[start - 1] == "[" { mid = "x" }
        return String(o[..<start]) + mid + String(o[end...])
    }

    /// Vditor serializes a ticked task as `- [X]  text`; write the common `- [x] text` instead.
    static func fixTaskMarker(_ line: Substring) -> Substring {
        guard let r = line.range(of: #"^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]  "#, options: .regularExpression) else { return line }
        let head = line[r]
        let fixed = head.replacingOccurrences(of: "[X]", with: "[x]").dropLast(1)
        return Substring(fixed) + line[r.upperBound...]
    }

    /// Longest-common-subsequence alignment: for each element of `to`, the matching index in `from`.
    private static func align<T: Hashable>(from: [T], to: [T]) -> [Int?] {
        let diff = to.difference(from: from)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var map = [Int?](repeating: nil, count: to.count)
        var f = 0
        for t in to.indices where !inserted.contains(t) {
            while removed.contains(f) { f += 1 }
            map[t] = f
            f += 1
        }
        return map
    }
}
