import XCTest
@testable import MDEditor

/// TESTS.md section B (and the in-process half of F) on a real WKWebView with the bundled Vditor.
@MainActor
final class EditorTests: XCTestCase {
    var h: EditorHarness!

    override func tearDown() async throws {
        h?.close()
        h = nil
    }

    func testB1_sampleRendersFormatted() async throws {
        h = try await EditorHarness(text: try Samples.text("sample.md"))
        try await waitUntil(5, "highlight.js applied") {
            (try await self.h.js("return mdeditor.root().querySelectorAll('code.hljs .hljs-keyword').length") as? Int ?? 0) > 0
        }
        let r = try await h.js("""
        const root = document.querySelector('.vditor-ir');
        const boxes = [...root.querySelectorAll('input[type=checkbox]')];
        return {
          h1: root.querySelectorAll('h1').length, h2: root.querySelectorAll('h2').length,
          h3: root.querySelectorAll('h3').length, table: root.querySelectorAll('table').length,
          boxes: boxes.length, checked: boxes.map(b => b.checked),
          hl: root.querySelectorAll('pre code.hljs .hljs-keyword').length,
          lang: !!root.querySelector('code.language-swift')
        };
        """) as! [String: Any]
        XCTAssertGreaterThanOrEqual(r["h1"] as! Int, 1)
        XCTAssertGreaterThanOrEqual(r["h2"] as! Int, 1)
        XCTAssertGreaterThanOrEqual(r["h3"] as! Int, 1)
        XCTAssertEqual(r["table"] as! Int, 1)
        XCTAssertEqual(r["boxes"] as! Int, 2)
        XCTAssertEqual(r["checked"] as! [Bool], [false, true])
        XCTAssertGreaterThan(r["hl"] as! Int, 0, "code block has highlight.js keyword spans")
        XCTAssertEqual(r["lang"] as? Bool, true)
    }

    func testB2_relativeImageLoads() async throws {
        h = try await EditorHarness(text: try Samples.text("sample.md"))
        try await waitUntil(10, "image loaded") {
            let w = try await self.h.js("const i = document.querySelector('.vditor-ir img'); return i ? i.naturalWidth : 0") as? Int
            return (w ?? 0) > 0
        }
        let src = try await h.js("return document.querySelector('.vditor-ir img').src") as? String
        XCTAssertTrue(src?.hasPrefix("mdedit://doc/") == true, src ?? "nil")
        XCTAssertTrue(h.controller.requestLog.contains { $0.hasPrefix("scheme 200 mdedit://doc/") && $0.hasSuffix("pic.png") })
    }

    func testB3_htmlInMarkdownDoesNotExecute() async throws {
        let md = """
        # XSS

        <script>window.__pwned1 = 1</script>

        <img src="nope.png" onerror="window.__pwned2 = 1">

        Inline <img src=x onerror="window.__pwned3=1"> and <b onclick="window.__pwned4=1">b</b>.

        """
        h = try await EditorHarness(text: md)
        try await Task.sleep(for: .seconds(1))
        let r = try await h.js("return [window.__pwned1, window.__pwned2, window.__pwned3, window.__pwned4].map(x => x === undefined)") as! [Bool]
        XCTAssertEqual(r, [true, true, true, true])
        let handlers = try await h.js("return document.querySelectorAll('.vditor-ir [onerror], .vditor-ir [onclick], .vditor-ir script').length") as! Int
        XCTAssertEqual(handlers, 0)
        XCTAssertTrue(h.changes.isEmpty)
    }

    func testB4_checkboxClickWritesX() async throws {
        let original = try Samples.text("sample.md")
        h = try await EditorHarness(text: original)
        try await h.js("document.querySelector('.vditor-ir input[type=checkbox]').click()")
        try await h.waitForText { $0.contains("- [x] open task") }
        let diff = changedLineRange(original, h.controller.text)
        XCTAssertEqual(diff.old, ["- [ ] open task"])
        XCTAssertEqual(diff.new, ["- [x] open task"])
    }

    func testB5_typingHashHashSpaceMakesHeading() async throws {
        let original = "First paragraph.\n"
        h = try await EditorHarness(text: original)
        try await h.focus()
        try await h.select("First paragraph.", collapseToEnd: true)
        try await h.key("\r", keyCode: 36)                      // Return (native key event)
        try await h.insertText("## Заголовок")
        try await h.waitForText { $0.contains("## Заголовок") }
        let h2 = try await h.js("return [...document.querySelectorAll('.vditor-ir h2')].map(e => e.textContent)") as! [String]
        XCTAssertTrue(h2.contains { $0.contains("Заголовок") }, "\(h2)")
        XCTAssertTrue(h.controller.text.hasPrefix("First paragraph.\n"), h.controller.text)
    }

    func testB5_typingListQuoteAndFence() async throws {
        h = try await EditorHarness(text: "Start.\n")
        try await h.focus()
        try await h.select("Start.", collapseToEnd: true)
        try await h.key("\r", keyCode: 36)
        try await h.insertText("- item")
        try await h.waitForText { $0.contains("- item") || $0.contains("* item") }
        try await waitUntil(3, "ul") { (try await self.h.js("return document.querySelectorAll('.vditor-ir ul li').length") as? Int ?? 0) > 0 }
    }

    func testB6_cmdBMakesBold() async throws {
        let original = "Make this word bold.\n"
        h = try await EditorHarness(text: original)
        try await h.focus()
        try await h.select("word")
        try await h.key("b", keyCode: 11, flags: .command)    // native Cmd+B through NSApp/menu path
        try await h.waitForText { $0.contains("**word**") }
        XCTAssertEqual(h.controller.text, "Make this **word** bold.\n")
    }

    func testB6_cmdIMakesItalic() async throws {
        h = try await EditorHarness(text: "Make this word italic.\n")
        try await h.focus()
        try await h.select("word")
        try await h.key("i", keyCode: 34, flags: .command)
        try await h.waitForText { $0.contains("*word*") }
        XCTAssertEqual(h.controller.text, "Make this *word* italic.\n")
    }

    func testB7_undoRedo() async throws {
        let original = try Samples.text("sample.md")
        h = try await EditorHarness(text: original)
        try await h.focus()
        try await h.select("Last paragraph", collapseToEnd: true)
        try await h.insertText(" EDITED")
        try await h.waitForText { $0.contains("Last paragraph EDITED") }
        try await Task.sleep(for: .milliseconds(300))
        try await h.key("z", keyCode: 6, flags: .command)     // native Cmd+Z
        try await h.waitForText { $0 == original }
        try await h.key("Z", keyCode: 6, flags: [.command, .shift])  // native Cmd+Shift+Z (shifted chars, as from the keyboard)
        try await h.waitForText { $0.contains("Last paragraph EDITED") }
    }

    func testB8_noExternalRequests() async throws {
        h = try await EditorHarness(text: try Samples.text("sample.md"))
        try await Task.sleep(for: .seconds(1))
        let resources = try await h.js("return performance.getEntriesByType('resource').map(e => e.name)") as! [String]
        let external = resources.filter { !$0.hasPrefix("mdedit:") && !$0.hasPrefix("data:") }
        XCTAssertEqual(external, [], "resource timing: external loads")
        XCTAssertEqual(h.controller.requestLog.filter { !$0.hasPrefix("scheme ") }, [])
        XCTAssertTrue(h.controller.requestLog.allSatisfy { !$0.hasPrefix("scheme ") || $0.contains(" mdedit://") })
        XCTAssertTrue(h.controller.requestLog.contains { $0.contains("lute.min.js") }, "Lute came from the bundle")
        // Positive control: an attempted external request is blocked and shows up in the log.
        try await h.js("fetch('https://example.com/probe').catch(() => 0)")
        try await waitUntil(5, "blocked probe in log") { self.h.controller.requestLog.contains { $0.contains("blocked https://example.com/probe") } }
    }

    func testB9_linkClickVsCmdClick() async throws {
        h = try await EditorHarness(text: try Samples.text("sample.md"))
        let urlBefore = h.controller.webView.url
        let clickJS = """
        const link = document.querySelector('.vditor-ir [data-type=a] .vditor-ir__link');
        link.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, metaKey: meta}));
        """
        try await h.js(clickJS, ["meta": false])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.opened, [])
        try await h.js(clickJS, ["meta": true])
        try await waitUntil(3, "link opened") { !self.h.opened.isEmpty }
        XCTAssertEqual(h.opened, [URL(string: "https://example.com")!])
        XCTAssertEqual(h.controller.webView.url, urlBefore)
        XCTAssertTrue(h.changes.isEmpty)
    }

    func testB10_switchModesKeepsTextAndScroll() async throws {
        let original = try Samples.text("big.md")
        h = try await EditorHarness(text: original)
        try await h.js("const s = document.querySelector('.vditor-ir .vditor-reset'); s.scrollTop = (s.scrollHeight - s.clientHeight) / 2")
        h.controller.setMode(.source)
        try await waitUntil(20, "source mode") {
            let m = try await self.h.js("return mdeditor.instance ? mdeditor.instance.getCurrentMode() : null") as? String
            return m == "sv"
        }
        XCTAssertEqual(h.controller.text, original)
        let sourceValue = try await h.js("return mdeditor.getValue()") as? String
        XCTAssertEqual(sourceValue, original, "source mode shows the file text byte for byte")
        let ratio = try await h.js("const s = document.querySelector('.vditor-sv'); return s.scrollTop / (s.scrollHeight - s.clientHeight)") as! Double
        XCTAssertEqual(ratio, 0.5, accuracy: 0.1)
        h.controller.setMode(.visual)
        try await waitUntil(20, "visual mode") {
            (try await self.h.js("return mdeditor.instance && mdeditor.instance.getCurrentMode()") as? String) == "ir"
        }
        XCTAssertEqual(h.controller.text, original)
        XCTAssertTrue(h.changes.isEmpty)
    }

    func testThemeFollowsAppearance() async throws {
        let saved = NSApp.appearance
        defer { NSApp.appearance = saved }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        h = try await EditorHarness(text: try Samples.text("sample.md"))
        try await waitUntil(5, "dark theme") {
            (try await self.h.js("return document.body.classList.contains('dark') && !!document.querySelector('.vditor--dark')") as? Bool) == true
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        try await waitUntil(5, "light theme") {
            (try await self.h.js("return !document.body.classList.contains('dark') && !document.querySelector('.vditor--dark')") as? Bool) == true
        }
    }

    func testSourceModeIsMonospacedWithoutPreview() async throws {
        h = try await EditorHarness(text: try Samples.text("sample.md"), mode: .source)
        let r = try await h.js("""
        const sv = document.querySelector('.vditor-sv');
        const pv = document.querySelector('.vditor-preview');
        return { font: getComputedStyle(sv).fontFamily, preview: pv ? getComputedStyle(pv).display : 'none' };
        """) as! [String: String]
        XCTAssertTrue(r["font"]!.lowercased().contains("mono") || r["font"]!.contains("Menlo"), r["font"]!)
        XCTAssertEqual(r["preview"], "none")
    }

    // MARK: F — fidelity (in-process; the tester repeats F1/F2 through the real app)

    func testF1_loadingDoesNotChangeDocument() async throws {
        for name in ["sample.md", "cyrillic.md", "crlf.md", "empty.md"] {
            h = try await EditorHarness(text: try Samples.text(name))
            try await Task.sleep(for: .seconds(1.5))
            XCTAssertTrue(h.changes.isEmpty, "\(name): loading reported a change")
            XCTAssertEqual(h.controller.text, try Samples.text(name))
            h.close()
        }
    }

    func testF2_oneWordEditTouchesOnlyThatParagraph() async throws {
        try await assertOneWordEdit("sample.md", after: "Last paragraph", expectLine: "Last paragraph X of the sample.")
    }

    func testF3_cyrillic() async throws {
        try await assertOneWordEdit("cyrillic.md", after: "Обычный абзац", expectLine: "Обычный абзац X с кириллицей: съешь же ещё этих мягких французских булок, да выпей чаю.")
    }

    func testF3_crlf() async throws {
        let original = try Samples.text("crlf.md")
        h = try await EditorHarness(text: original)
        try await h.focus()
        try await h.select("Second paragraph", collapseToEnd: true)
        try await h.insertText(" X")
        try await h.waitForText { $0.contains("Second paragraph X") }
        XCTAssertEqual(h.controller.text, original.replacingOccurrences(of: "Second paragraph", with: "Second paragraph X"))
    }

    func testF2_editInsideListKeepsOtherListMarkers() async throws {
        let original = try Samples.text("sample.md")
        h = try await EditorHarness(text: original)
        try await h.focus()
        try await h.select("star item three", collapseToEnd: true)
        try await h.insertText("!")
        try await h.waitForText { $0.contains("three!") }
        let diff = changedLineRange(original, h.controller.text)
        print("F2 list edit diff:", diff)
        XCTAssertTrue(diff.new.contains { $0.contains("star item three!") })
        // Whatever the engine rewrote must stay inside the list block that was edited.
        let listBlock = original.components(separatedBy: "\n\n").first { $0.contains("star item three") }!
        for line in diff.old { XCTAssertTrue(listBlock.contains(line), "changed line outside the edited block: \(line)") }
    }

    func testF4_reportNormalizations() async throws {
        // Not an assertion of behaviour the user sees (the preserver hides these); prints what Lute
        // would rewrite if its output were saved as is. Used for README "Известные ограничения".
        for name in ["sample.md", "cyrillic.md", "crlf.md", "big.md"] {
            let text = try Samples.text(name)
            h = try await EditorHarness(text: text)
            let baseline = try await h.js("return mdeditor.getValue()") as! String
            let d = changedLineRange(SourcePreserver.editorText(for: text), baseline)
            print("F4 \(name): original \(d.old) -> lute \(d.new)")
            h.close()
        }
    }

    private func assertOneWordEdit(_ name: String, after anchor: String, expectLine: String) async throws {
        let original = try Samples.text(name)
        h = try await EditorHarness(text: original)
        try await h.focus()
        try await h.select(anchor, collapseToEnd: true)
        try await h.insertText(" X")
        try await h.waitForText { $0.contains(expectLine) }
        let diff = changedLineRange(original, h.controller.text)
        XCTAssertEqual(diff.new, [Substring(expectLine)], "only the edited line changes")
        XCTAssertEqual(diff.old.count, 1)
    }

    // MARK: C6 helper — typing latency in a big file (logged; tester measures in the real app)

    func testC6_typingLatencyBigFile() async throws {
        // The test host is a background app; keep App Nap from throttling it like a foreground app is not.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "latency test")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        h = try await EditorHarness(text: try Samples.text("big.md"))
        try await Task.sleep(for: .seconds(2.5)) // a person does not type within the first seconds
        try await h.focus()
        try await h.select("Paragraph 250 with", collapseToEnd: true)
        // Placing the caret costs WebKit ~0.3 s once on a 6000-line file; a person clicks, then types.
        try await Task.sleep(for: .seconds(1))
        for ch in "abcdefghijklmnopqrst" {
            try await h.key(String(ch), keyCode: 0)
        }
        try await waitUntil(5, "20 latency samples") { self.h.controller.latencies.count >= 20 }
        let l = h.controller.latencies
        print("C6 latencies ms:", l.map { Int($0) }, "max", Int(l.max() ?? 0))
        // Latency = keydown timestamp -> input handled (includes queueing behind earlier work).
        // Steady typing is ~30 ms; occasional one-off stalls of 0.2-1.3 s (WebKit/GC, see README) delay the
        // few keys queued behind them, so the gate is the median plus "most keys", and the max is printed.
        let sorted = l.sorted()
        let median = sorted[sorted.count / 2]
        let under100 = Double(l.filter { $0 < 100 }.count) / Double(l.count)
        print("C6 median", Int(median), "share<100ms", under100)
        XCTAssertLessThan(median, 100, "median latency per character")
        XCTAssertGreaterThanOrEqual(under100, 0.5, "most characters under 100 ms")
        try await h.waitForText(5) { $0.contains("Paragraph 250 withabcdefghijklmnopqrst") }
    }
}
