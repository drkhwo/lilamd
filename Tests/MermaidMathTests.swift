import AppKit
import CryptoKit
import WebKit
import XCTest
@testable import MDEditor

/// Mermaid diagrams and math formulas in the Visual editor (plan 1.0, task 1.6): what renders, and what the App Store text may say.
@MainActor
final class MermaidMathTests: XCTestCase {
    static let evidence = URL(fileURLWithPath: "/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0/MER")
    var dir: URL!
    var h: EditorHarness?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "mer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Self.evidence, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        h?.close()
        h = nil
        try? FileManager.default.removeItem(at: dir)
    }

    struct Facts {
        var mermaidSVG = false
        var blockMathKatex = false
        var inlineMathKatex = false
        var raw = ""
    }

    private func facts(_ h: EditorHarness) async throws -> Facts {
        let r = try await h.js("""
        const root = mdeditor.root();
        const has = (el) => !!el && !!el.querySelector('.katex');
        const blocks = [...root.querySelectorAll('[data-type="math-block"]')];
        const inlines = [...root.querySelectorAll('[data-type="math-inline"]')];
        // The preview of an inline formula is a sibling of the node in IR, so look at the node and its neighbours.
        const inlineOK = inlines.filter(el => has(el) || has(el.nextElementSibling) || has(el.previousElementSibling) || has(el.parentElement && el.parentElement.querySelector('.vditor-ir__preview'))).length;
        return {
          mermaidSVG: root.querySelectorAll('.language-mermaid svg').length,
          mermaidBlocks: root.querySelectorAll('[data-type="code-block"]').length,
          blockMathKatex: blocks.filter(has).length,
          mathBlocks: blocks.length,
          inlineMathKatex: inlineOK,
          mathInlines: inlines.length,
          blockHTML: blocks.map(b => b.outerHTML.slice(0, 500)),
          inlineParentHTML: inlines.map(i => i.parentElement.outerHTML.slice(0, 600))
        };
        """) as! [String: Any]
        var f = Facts()
        f.mermaidSVG = (r["mermaidSVG"] as? Int ?? 0) > 0
        f.blockMathKatex = (r["blockMathKatex"] as? Int ?? 0) > 0
        f.inlineMathKatex = (r["inlineMathKatex"] as? Int ?? 0) > 0
        f.raw = "\(r)"
        return f
    }

    private func openSample() async throws -> (OpenDocument, TabStore, URL) {
        let url = dir.appending(path: "mermaid-math.md")
        try Samples.data("mermaid-math.md").write(to: url)
        let store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false
        let doc = try store.open(url, activate: false)
        let controller = doc.makeController(mode: .visual, zoom: 1)
        h = try await EditorHarness(controller: controller)
        return (doc, store, url)
    }

    /// Waits until the previews settle: both kinds present, or the time is out (then the result is "no").
    private func settled(_ h: EditorHarness, seconds: Double = 10) async throws -> Facts {
        var f = try await facts(h)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !(f.mermaidSVG && f.blockMathKatex && f.inlineMathKatex) {
            try await Task.sleep(for: .milliseconds(300))
            f = try await facts(h)
        }
        try await Task.sleep(for: .milliseconds(500))
        return try await facts(h)
    }

    /// MER-1, MER-2, MER-3: what renders, no CSP block, the bytes stay.
    func testMER1_2_3_renderBlockedAndBytes() async throws {
        let (doc, store, url) = try await openSample()
        let h = try XCTUnwrap(self.h)
        let before = SHA256.hash(data: try Data(contentsOf: url))
        let f = try await settled(h)

        // The probe must have found the nodes it asks about, otherwise "no" would only mean "page not ready".
        let nodes = try await h.js("""
        const root = mdeditor.root();
        return { code: root.querySelectorAll('pre, [data-type="code-block"], [data-type="math-block"], [data-type="math-inline"]').length,
                 text: root.textContent.length };
        """) as! [String: Any]
        XCTAssertGreaterThan(nodes["code"] as? Int ?? 0, 0, "probe: the sample's blocks are in the DOM; \(f.raw)")

        let result = """
        sample: samples/mermaid-math.md (Visual mode, mathBlockPreview as set in editor.js)
        mermaid block renders to svg: \(f.mermaidSVG ? "yes" : "no")
        block math $$...$$ renders .katex: \(f.blockMathKatex ? "yes" : "no")
        inline math $...$ renders .katex: \(f.inlineMathKatex ? "yes" : "no")
        raw: \(f.raw)
        requestLog: \(h.controller.requestLog.filter { !$0.hasPrefix("scheme 200") })
        scheme requests: \(h.controller.requestLog.filter { $0.hasPrefix("scheme") }.count)
        """
        try result.write(to: Self.evidence.appending(path: "result.txt"), atomically: true, encoding: .utf8)
        print("MER-1 RESULT\n\(result)")

        // MER-2: nothing blocked, nothing left the app.
        let bad = h.controller.requestLog.filter { $0.hasPrefix("blocked") || $0.hasPrefix("navigation refused") || $0.hasPrefix("new window refused") }
        XCTAssertTrue(bad.isEmpty, "blocked or refused requests: \(bad)")
        let outside = h.controller.requestLog.filter { $0.hasPrefix("scheme") && !$0.contains(" mdedit://") }
        XCTAssertTrue(outside.isEmpty, "requests outside mdedit://: \(outside)")
        XCTAssertTrue(h.controller.requestLog.contains { $0.contains("mermaid") } || !f.mermaidSVG,
                      "mermaid rendered without loading its script?")

        // MER-3: open, render, close without edits: the file is byte for byte the same, the tab was not dirty.
        XCTAssertFalse(doc.isDirty, "rendering must not make the tab dirty")
        XCTAssertEqual(h.controller.text, try Samples.text("mermaid-math.md"), "editor text = file text")
        let closed = await store.close(doc.id)
        XCTAssertTrue(closed)
        let after = SHA256.hash(data: try Data(contentsOf: url))
        XCTAssertEqual(before, after, "SHA-256 of the file after open and close")
    }

    /// MER-4: screenshots of the web view, light and dark. `takeSnapshot` works without the screen.
    func testMER4_screenshots() async throws {
        _ = try await openSample()
        let h = try XCTUnwrap(self.h)
        _ = try await settled(h)
        h.window.setContentSize(NSSize(width: 900, height: 1250)) // the whole sample in one picture
        try await Task.sleep(for: .milliseconds(800))
        for dark in [false, true] {
            try await h.js("mdeditor.setTheme(dark)", ["dark": dark])
            try await Task.sleep(for: .milliseconds(1200))
            let config = WKSnapshotConfiguration()
            let image = try await h.controller.webView.takeSnapshot(configuration: config)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no PNG") }
            let name = dark ? "dark.png" : "light.png"
            try png.write(to: Self.evidence.appending(path: name))
            // Not blank: more than a few distinct colors.
            var colors = Set<UInt32>()
            let step = max(1, rep.pixelsWide / 60)
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                        colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
                    }
                }
            }
            print("MER-4 \(name) \(rep.pixelsWide)x\(rep.pixelsHigh) distinctColors=\(colors.count)")
            XCTAssertGreaterThan(colors.count, 3, "\(name) is not blank")
        }
    }
}
