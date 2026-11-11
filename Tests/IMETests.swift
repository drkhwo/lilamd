import AppKit
import WebKit
import XCTest
@testable import MDEditor

/// Input in other languages (plan 1.0, task 1.2). Composition is driven in the background, without the screen.
/// Path A: `NSTextInputClient` of the WKWebView (`setMarkedText` / `insertText`): WebKit fires the composition events.
/// Path B (fallback): the same event sequence made by JS in the page. `IMEHarness.path` says which one ran.
@MainActor
final class IMETests: XCTestCase {
    var h: EditorHarness!
    var ime: IMEHarness!

    override func tearDown() async throws {
        h?.close()
        h = nil
        ime = nil
    }

    private func open(_ text: String) async throws {
        h = try await EditorHarness(text: text)
        ime = IMEHarness(h)
        try await ime.install()
    }

    /// IME-1: the page sees the composition events. Records which path works.
    func testIME1_compositionPathIsProven() async throws {
        try await open("# Title\n\nfirst paragraph\n")
        try await h.select("first paragraph", collapseToEnd: true)
        let path = try await ime.compose(marked: ["п", "пр", "привет"], commit: "привет")
        let log = try await ime.log()
        let starts = log.filter { $0.hasPrefix("compositionstart") }.count
        let ends = log.filter { $0.hasPrefix("compositionend") }.count
        let line = "IME-1 path=\(path) compositionstart=\(starts) compositionend=\(ends) log=\(log.joined(separator: " | "))"
        print(line)
        IMEHarness.record(line)
        XCTAssertGreaterThan(starts, 0, line)
        XCTAssertGreaterThan(ends, 0, line)
    }

    // MARK: places

    struct Place {
        let name: String
        let doc: String
        /// JS (async function body, `root` = editor root) that puts the caret.
        let caret: String
        /// Expected text; `$` stands for the committed string.
        let expected: String
    }

    static let places: [Place] = [
        Place(name: "paragraph", doc: "# Title\n\nfirst paragraph\n\nlast paragraph\n", caret: "SELECT:first paragraph",
              expected: "# Title\n\nfirst paragraph$\n\nlast paragraph\n"),
        Place(name: "heading", doc: "# Title\n\nfirst paragraph\n\nlast paragraph\n", caret: "SELECT:Title",
              expected: "# Title$\n\nfirst paragraph\n\nlast paragraph\n"),
        Place(name: "table cell", doc: "intro\n\n| alpha | beta |\n| --- | --- |\n| gamma | delta |\n\nlast\n", caret: "SELECT:gamma",
              expected: "intro\n\n| alpha | beta |\n| --- | --- |\n| gamma$ | delta |\n\nlast\n"),
        Place(name: "list item", doc: "- one\n- two\n- three\n", caret: "SELECT:two",
              expected: "- one\n- two$\n- three\n"),
        Place(name: "first line, empty document", doc: "", caret: "ROOTSTART",
              expected: "$\n"),
        Place(name: "table at document start", doc: "| alpha | beta |\n| --- | --- |\n| gamma | delta |\n\nlast\n", caret: "ROOTSTART",
              expected: "| $alpha | beta |\n| --- | --- |\n| gamma | delta |\n\nlast\n"),
        Place(name: "caret in root after the last code block", doc: "```\ncode\n```\n", caret: "ROOTEND",
              expected: "```\ncode\n```\n\n$\n"),
    ]

    private func placeCaret(_ caret: String) async throws {
        if caret.hasPrefix("SELECT:") {
            try await h.select(String(caret.dropFirst(7)), collapseToEnd: true)
        } else {
            try await h.js("""
            mdeditor.instance.focus();
            const root = mdeditor.root();
            const r = document.createRange();
            r.setStart(root, start ? 0 : root.childNodes.length); r.collapse(true);
            const s = getSelection(); s.removeAllRanges(); s.addRange(r);
            """, ["start": caret == "ROOTSTART"])
        }
    }

    /// Runs the composition in every place. Failures name the place and show the real text.
    private func runPlaces(marked: [String], commit: String, forceB: Bool = false, only: Set<String>? = nil) async throws {
        for place in Self.places where only == nil || only!.contains(place.name) {
            try await open(place.doc)
            ime.forceB = forceB
            try await placeCaret(place.caret)
            let path = try await ime.compose(marked: marked, commit: commit)
            try await h.waitForText { _ in true }
            try await Task.sleep(for: .milliseconds(1200)) // the lazy Markdown (editor.js LAZY) arrives by timer
            let text = h.controller.text
            let expected = place.expected.replacingOccurrences(of: "$", with: commit)
            XCTAssertEqual(text, expected, "[\(place.name)] path \(path) commit \(commit)")
            XCTAssertEqual(text.components(separatedBy: commit).count - 1, 1, "[\(place.name)] commit must appear once; text: \(text.debugDescription)")
            // IME-5: caret right after the inserted text; the next character goes after it.
            let caret = try await h.js("""
            const s = getSelection(); const n = s.anchorNode;
            return { collapsed: s.isCollapsed, before: n ? (n.textContent || "").slice(0, s.anchorOffset) : null };
            """) as? [String: Any]
            XCTAssertEqual(caret?["collapsed"] as? Bool, true, "[\(place.name)] caret collapsed")
            XCTAssertTrue((caret?["before"] as? String ?? "").hasSuffix(commit), "[\(place.name)] caret after the commit; before=\(String(describing: caret?["before"]))")
            try await h.insertText("X")
            try await h.waitForText { $0.contains(commit + "X") }
            XCTAssertEqual(h.controller.text, expected.replacingOccurrences(of: commit, with: commit + "X"), "[\(place.name)] next character")
            h.close()
        }
    }

    /// IME-6: the autosave (0.2 s) fires while a 1 s composition is on; the text must survive and the file equal the text.
    func testIME6_autosaveDuringComposition() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ime-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "ime.md")
        let original = "# Title\n\nfirst paragraph\n"
        try Data(original.utf8).write(to: url)
        let saved = OpenDocument.autosaveDelay
        OpenDocument.autosaveDelay = .milliseconds(200)
        defer { OpenDocument.autosaveDelay = saved }

        let doc = try OpenDocument(contentsOf: url)
        let prompter = FakePrompter()
        var autosaves: [(at: Date, file: String)] = []
        doc.onAutosave = { d in
            _ = await d.save(prompter: prompter, reason: .autosave)
            autosaves.append((Date(), (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"))
        }
        let controller = doc.makeController(mode: .visual, zoom: 1)
        h = try await EditorHarness(controller: controller)
        ime = IMEHarness(h)
        try await ime.install()
        // editor.js refreshes the undo base 0.6 s and 2 s after load (IME-10 covers typing in that window).
        try await Task.sleep(for: .milliseconds(2500))
        try await h.select("first paragraph", collapseToEnd: true)
        // An edit just before the composition: Vditor reports it 0.15 s later, the autosave runs 0.2 s after that,
        // so it lands inside the composition. (An edit made during the composition is reported only after the commit.)
        try await h.insertText("A")
        try await Task.sleep(for: .milliseconds(250))
        let commit = "你好世界"
        let started = Date()
        try await ime.compose(marked: ["ni h", "ni hao"], commit: commit, hold: .milliseconds(500))
        let committed = Date()
        try await Task.sleep(for: .milliseconds(1500))
        let expected = "# Title\n\nfirst paragraphA\(commit)\n"
        XCTAssertEqual(h.controller.text, expected)
        XCTAssertEqual(doc.text, expected)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected, "file = text after the commit")
        let during = autosaves.filter { $0.at > started && $0.at < committed.addingTimeInterval(-0.1) }
        XCTAssertEqual(during.count, 1, "one autosave ran while the marked text was on: \(autosaves)")
        XCTAssertEqual(during.first?.file, "# Title\n\nfirst paragraphA\n", "that autosave wrote the text before the composition")
        XCTAssertEqual(h.controller.text.components(separatedBy: commit).count - 1, 1)
        XCTAssertTrue(prompter.calls.isEmpty, "no question during autosave: \(prompter.calls)")
        let log = try await ime.log()
        XCTAssertEqual(log.filter { $0.hasPrefix("compositionend") }.count, 1, "one compositionend; the composition was not reset: \(log)")
        doc.watcher.watch(nil)
    }

    /// IME-10a: a composition that is on at 0.6 s after load (editor.js `refreshUndoBase` timer) must not be cancelled.
    func testIME10a_compositionAcrossUndoBaseTimer() async throws {
        try await open("# Title\n\nfirst paragraph\n")
        try await h.select("first paragraph", collapseToEnd: true)
        let commit = "你好世界"
        try await ime.compose(marked: ["ni hao"], commit: commit, hold: .milliseconds(1000))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(h.controller.text, "# Title\n\nfirst paragraph\(commit)\n")
        let log = try await ime.log()
        XCTAssertEqual(log.filter { $0.hasPrefix("compositionend") }.count, 1, "composition ran to its end once: \(log)")
    }

    /// IME-10b: keys of a composition (keydown 229, isComposing true) before the undo base is refreshed must not touch the DOM.
    func testIME10b_keydownDuringCompositionBeforeIdle() async throws {
        try await open("# Title\n\nfirst paragraph\n")
        try await h.select("first paragraph", collapseToEnd: true)
        let commit = "你好世界"
        try await ime.compose(marked: ["n", "ni", "ni h", "ni hao"], commit: commit, hold: .milliseconds(60))
        try await Task.sleep(for: .milliseconds(2500))
        XCTAssertEqual(h.controller.text, "# Title\n\nfirst paragraph\(commit)\n")
        let log = try await ime.log()
        XCTAssertEqual(log.filter { $0.hasPrefix("compositionend") }.count, 1, "composition ran to its end once: \(log)")
        XCTAssertEqual(log.filter { $0.hasPrefix("compositionstart") }.count, 1, "composition started once: \(log)")
    }

    /// IME-2
    func testIME2_russian() async throws { try await runPlaces(marked: ["п", "пр", "прив", "привет"], commit: "привет") }
    /// IME-3
    func testIME3_pinyin() async throws { try await runPlaces(marked: ["n", "ni", "ni h", "ni hao"], commit: "你好世界") }
    /// IME-4
    func testIME4_kana() async throws { try await runPlaces(marked: ["こ", "こん", "こんに", "こんにち"], commit: "こんにちは") }
    /// Path B (JS simulation) on all three, so the fallback is also proven.
    func testIME2B_fallbackPathB() async throws {
        try await runPlaces(marked: ["n", "ni", "ni hao"], commit: "你好世界", forceB: true)
    }
}

/// Drives a composition on an `EditorHarness`.
@MainActor
final class IMEHarness {
    enum Path: String { case A, B }
    let h: EditorHarness
    private(set) var path: Path = .A
    /// Forces path B (used to prove that the fallback also works).
    var forceB = false

    init(_ h: EditorHarness) { self.h = h }

    static let evidence = "/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0/IME/path.txt"
    static func record(_ line: String) {
        let url = URL(fileURLWithPath: evidence)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func install() async throws {
        try await h.js("""
        window.__ime = [];
        for (const t of ["keydown", "compositionstart", "compositionupdate", "compositionend", "beforeinput", "input"]) {
          document.addEventListener(t, (e) => {
            window.__ime.push(t + ":" + (e.data === undefined || e.data === null ? "" : e.data) + ":comp=" + (e.isComposing ? 1 : 0)
              + (t === "keydown" ? ":kc=" + e.keyCode : "") + (e.inputType ? ":" + e.inputType : "")
              + ":lock=" + (window.mdeditor.instance ? window.mdeditor.instance.vditor.ir.composingLock : "?"));
          }, true);
        }
        """)
    }

    func log() async throws -> [String] {
        (try await h.js("return window.__ime") as? [String]) ?? []
    }

    func clearLog() async throws { try await h.js("window.__ime = []") }

    /// Marked text steps, then the commit. Returns the path that ran.
    @discardableResult
    func compose(marked: [String], commit: String, hold: Duration = .milliseconds(30)) async throws -> Path {
        try await h.focus()
        if !forceB, await composeA(marked: marked, commit: commit, hold: hold) { path = .A; return .A }
        try await clearLog()
        path = .B
        try await composeB(marked: marked, commit: commit, hold: hold)
        return .B
    }

    /// What WebKit does when the user presses the next key of a composition: keydown, keyCode 229. The first one comes
    /// before `compositionstart` (isComposing false); the later ones come while the composition is on (isComposing true).
    /// `lateKeydownIsComposing = false` is the harsh case (an IME whose later keydowns also report false).
    var lateKeydownIsComposing = true

    static func keydown229(composing: Bool) -> String {
        """
        (document.activeElement || document.body).dispatchEvent(new KeyboardEvent("keydown",
          { key: "n", code: "KeyN", keyCode: 229, isComposing: \(composing), bubbles: true, cancelable: true }));
        """
    }

    private func composeA(marked: [String], commit: String, hold: Duration) async -> Bool {
        guard let client = h.controller.webView as? NSTextInputClient else { return false }
        let none = NSRange(location: NSNotFound, length: 0)
        for (i, m) in marked.enumerated() {
            try? await h.js(Self.keydown229(composing: i > 0 && lateKeydownIsComposing))
            client.setMarkedText(m, selectedRange: NSRange(location: (m as NSString).length, length: 0), replacementRange: none)
            try? await Task.sleep(for: hold)
        }
        let before = (try? await log()) ?? []
        guard before.contains(where: { $0.hasPrefix("compositionstart") }) else {
            // WebKit did not accept marked text (no focus in the background): drop it and use path B.
            client.unmarkText()
            return false
        }
        client.insertText(commit, replacementRange: none)
        try? await Task.sleep(for: .milliseconds(150))
        return true
    }

    private func composeB(marked: [String], commit: String, hold: Duration) async throws {
        // keydown 229 as WebKit sends it for the key that starts a composition (isComposing false), then the events.
        try await h.js("""
        const el = document.activeElement || document.body;
        const fire = (type, init) => el.dispatchEvent(type.startsWith("composition")
          ? new CompositionEvent(type, Object.assign({ bubbles: true, cancelable: true }, init))
          : new KeyboardEvent(type, Object.assign({ bubbles: true, cancelable: true }, init)));
        fire("keydown", { key: "n", code: "KeyN", keyCode: 229, isComposing: false });
        fire("compositionstart", { data: "" });
        let first = true;
        let markedLen = 0;
        for (const m of marked) {
          const sel = getSelection();
          for (let i = 0; i < markedLen; i++) sel.modify("extend", "backward", "character");
          document.execCommand("insertText", false, m);
          markedLen = [...m].length;
          fire("compositionupdate", { data: m });
        }
        const sel = getSelection();
        for (let i = 0; i < markedLen; i++) sel.modify("extend", "backward", "character");
        document.execCommand("insertText", false, commit);
        fire("compositionend", { data: commit });
        fire("keyup", { key: "Process", code: "KeyA", keyCode: 229 });
        """, ["marked": marked, "commit": commit])
        try await Task.sleep(for: .milliseconds(150))
    }
}
