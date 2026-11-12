import AppKit
import XCTest
@testable import MDEditor

/// File ▸ Close Tab from the menu (1.4). The menu action goes to the app's own window (`AppDelegate.shared`),
/// so these tests use that window and swap a fake prompter into its store. Files are temporary copies.
@MainActor
final class CloseTabTests: XCTestCase {
    private var dir: URL!
    private var fake: FakePrompter!
    private var savedPrompter: SavePrompting?
    private var autosaveDelay = OpenDocument.autosaveDelay

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appending(path: "closetab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        autosaveDelay = OpenDocument.autosaveDelay
        fake = FakePrompter()
        let app = try XCTUnwrap(AppDelegate.shared, "AppDelegate.shared")
        savedPrompter = app.store.prompter
        app.store.prompter = fake
    }

    override func tearDown() async throws {
        if let app = AppDelegate.shared {
            fake.closeChoice = .discard
            for doc in app.store.tabs { await app.store.close(doc.id) }
            app.mainWindow.window?.orderOut(nil)
            if let savedPrompter { app.store.prompter = savedPrompter }
        }
        OpenDocument.autosaveDelay = autosaveDelay
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    // MARK: Helpers

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// File ▸ Close Tab, the same call AppKit makes when the item is clicked or its key equivalent fires.
    private func pressCloseTab() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu, "File menu")
        let index = menu.indexOfItem(withTitle: "Close Tab")
        XCTAssertGreaterThanOrEqual(index, 0, "File ▸ Close Tab")
        menu.performActionForItem(at: index)
    }

    private func typeAtEnd(_ s: String, in doc: OpenDocument) async throws {
        let ok = try await XCTUnwrap(doc.controller).evaluate("""
        mdeditor.instance.focus();
        const root = mdeditor.root();
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let last = null; while (walker.nextNode()) last = walker.currentNode;
        if (!last) return false;
        const r = document.createRange(); r.setStart(last, last.textContent.length); r.collapse(true);
        const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r);
        document.execCommand('insertText', false, s); return true;
        """, arguments: ["s": s]) as? Bool
        XCTAssertEqual(ok, true, "caret placed in \(doc.displayName)")
    }

    // MARK: CLOSE-1

    /// CLOSE-1: with no key window (a menu item pressed through AX, VoiceOver, Shortcuts; right after the app
    /// becomes active again) File ▸ Close Tab still closes the active tab of the app's window.
    func testCloseTabFromMenuWithoutKeyWindowClosesActiveTab() async throws {
        try XCTSkipUnless(NSApp.keyWindow == nil, "this test checks the branch without a key window; the foreground run has one")
        let app = try XCTUnwrap(AppDelegate.shared)
        let a = try file("a.md", "Alpha\n")
        let b = try file("b.md", "Beta\n")
        app.mainWindow.open([a, b])
        XCTAssertEqual(app.store.active?.url, b)
        try pressCloseTab()
        try await waitUntil(5, "b.md closed") { app.store.tab(for: b) == nil }
        XCTAssertEqual(app.store.tabs.map(\.displayName), ["a.md"])
        XCTAssertEqual(fake.calls, [])
    }

    // MARK: CLOSE-2

    /// CLOSE-2: which window File ▸ Close Tab acts on.
    func testCloseTargetChoice() throws {
        let store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false
        let main = MainWindowController(store: store)
        defer { main.window?.close() }
        let fallback = MainWindowController(store: TabStore(prompter: FakePrompter()))
        defer { fallback.window?.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false

        // The key window is a main window: its active tab.
        guard case .tab(let m1) = AppDelegate.closeTarget(keyWindow: main.window, fallback: fallback) else { return XCTFail("main window → tab") }
        XCTAssertTrue(m1 === main)
        // Another key window (an alert, a panel): it just closes.
        guard case .window(let w) = AppDelegate.closeTarget(keyWindow: other, fallback: fallback) else { return XCTFail("other window → close it") }
        XCTAssertTrue(w === other)
        // No key window: the app's main window.
        guard case .tab(let m2) = AppDelegate.closeTarget(keyWindow: nil, fallback: fallback) else { return XCTFail("no key window → fallback tab") }
        XCTAssertTrue(m2 === fallback)
    }

    // MARK: CLOSE-6

    /// CLOSE-6: two Close Tab calls in a row on Untitled with text ask "Save?" once, not twice.
    func testTwoClosesOnUntitledAskOnce() async throws {
        let slow = SlowAnswerPrompter()
        let store = TabStore(prompter: slow)
        store.recordsRecents = false
        let doc = store.newUntitled()
        doc.editorChanged("Draft\n")
        async let first = store.close(doc.id)
        async let second = store.close(doc.id)
        let results = await [first, second]
        XCTAssertEqual(slow.asked, 1, "one question for two closes")
        XCTAssertEqual(results, [true, true])
        XCTAssertTrue(store.tabs.isEmpty)
    }

    // MARK: CLOSE-3 probe

    /// CLOSE-3: 100 runs of edit → 0.3 s or 2.0 s → File ▸ Close Tab, in the app's window without a key window.
    /// About 3–4 minutes, so it runs only on request:
    /// `TEST_RUNNER_MDEDITOR_CLOSE_PROBE=100 scripts/test.sh -only-testing:MDEditorTests/CloseTabTests/testCloseTabProbe`.
    /// Every run is counted; a failed run does not stop the loop. Counters go to `MDEDITOR_CLOSE_PROBE_LOG` (a path).
    func testCloseTabProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let runs = env["MDEDITOR_CLOSE_PROBE"].flatMap(Int.init), runs > 0 else {
            throw XCTSkip("probe: set TEST_RUNNER_MDEDITOR_CLOSE_PROBE=<runs>")
        }
        let app = try XCTUnwrap(AppDelegate.shared)
        OpenDocument.autosaveDelay = .seconds(2)
        var lines: [String] = ["keyWindow=\(NSApp.keyWindow.map { "\($0)" } ?? "nil") isActive=\(NSApp.isActive) runs=\(runs)"]
        var pass = 0, fail = 0
        for run in 1...runs {
            let pause = run.isMultiple(of: 2) ? 2.0 : 0.3
            let name = String(format: "r%03d.md", run)
            let marker = " edit\(run)"
            let url = try file(name, "Line of \(name)\n")
            let callsBefore = fake.calls.count
            app.mainWindow.open([url])
            var reason: String?
            do {
                let doc = try XCTUnwrap(app.store.tab(for: url))
                try await waitUntil(20, "editor of \(name) ready") { doc.controller?.isReady == true }
                try await typeAtEnd(marker, in: doc)
                try await waitUntil(5, "edit in \(name)") { doc.text.contains(marker) }
                try await Task.sleep(for: .seconds(pause))
                try pressCloseTab()
                do {
                    try await waitUntil(5, "\(name) closed") { app.store.tab(for: url) == nil }
                } catch { reason = "tab still open" }
                if reason == nil {
                    let disk = try String(contentsOf: url, encoding: .utf8)
                    if !disk.contains(marker) { reason = "file lacks the edit: \(disk.debugDescription)" }
                }
                if reason == nil, fake.calls.count != callsBefore { reason = "questions: \(fake.calls[callsBefore...])" }
            } catch {
                reason = "setup: \(error)"
            }
            if let reason {
                fail += 1
                lines.append("run \(run) pause=\(pause) FAIL \(reason)")
                // Clean up, so the next run starts with an empty window.
                fake.closeChoice = .discard
                for doc in app.store.tabs { await app.store.close(doc.id) }
            } else {
                pass += 1
                lines.append("run \(run) pause=\(pause) PASS")
            }
        }
        lines.append("RESULT close-probe pass=\(pass) fail=\(fail) runs=\(runs)")
        let text = lines.joined(separator: "\n") + "\n"
        print(text)
        if let path = env["MDEDITOR_CLOSE_PROBE_LOG"] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(fail, 0, "failed runs: \(fail) of \(runs)")
    }
}

/// Answers Don't Save after a pause, so a second close can start while the first one waits for the answer.
@MainActor
private final class SlowAnswerPrompter: SavePrompting {
    private(set) var asked = 0

    func askToSave(_ doc: OpenDocument) async -> CloseChoice {
        asked += 1
        try? await Task.sleep(for: .milliseconds(300))
        return .discard
    }

    func askOverwrite(_ doc: OpenDocument) async -> OverwriteChoice { .cancel }
    func chooseSaveURL(for doc: OpenDocument) async -> URL? { nil }
    func showConflict(_ doc: OpenDocument) async -> NSApplication.ModalResponse { FileWatcher.keepResponse }
    func report(_ error: Error, for doc: OpenDocument) async {}
}
