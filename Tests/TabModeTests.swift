import AppKit
import XCTest
@testable import MDEditor

/// TB-26 (mode part): Visual / Source is one setting for every tab. The old multi-window build kept it per window scene.
@MainActor
final class TabModeTests: XCTestCase {
    private var dir: URL!
    private var store: TabStore!
    private var wc: MainWindowController!
    private var saved: Any?

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appending(path: "tabmode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saved = UserDefaults.standard.object(forKey: EditorModePreference.key)
        UserDefaults.standard.set(EditorMode.visual.rawValue, forKey: EditorModePreference.key)
        store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false
        wc = MainWindowController(store: store)
    }

    override func tearDown() async throws {
        for doc in store.tabs { await store.close(doc.id) }
        wc.window?.close()
        wc = nil
        if let saved { UserDefaults.standard.set(saved, forKey: EditorModePreference.key) }
        else { UserDefaults.standard.removeObject(forKey: EditorModePreference.key) }
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    /// Fails on a per-tab mode: tab A would stay visual after the switch to source made while tab B was shown.
    func testModeIsSharedByTabs() async throws {
        var urls: [URL] = []
        for name in ["a.md", "b.md"] {
            let url = dir.appending(path: name)
            try Data("# \(name)\n\nText\n".utf8).write(to: url)
            urls.append(url)
        }
        wc.open([urls[0]])
        let a = try XCTUnwrap(store.active)
        try await waitUntil(20, "a ready") { a.controller?.isReady == true }
        wc.open([urls[1]])
        let b = try XCTUnwrap(store.active)
        try await waitUntil(20, "b ready") { b.controller?.isReady == true }
        XCTAssertEqual(b.controller?.mode, .visual)

        // The toolbar picker writes this key; the visible tab (B) follows at once.
        UserDefaults.standard.set(EditorMode.source.rawValue, forKey: EditorModePreference.key)
        try await waitUntil(10, "visible tab B in source") { b.controller?.mode == .source }

        // A hidden tab takes the shared mode when it is shown again.
        store.activate(a.id)
        try await waitUntil(10, "tab A in source after activation") { a.controller?.mode == .source }
    }

    /// TB-15 (model): an Untitled tab has no file, so no proxy icon.
    func testUntitledTabHasNoURL() throws {
        let doc = store.newUntitled()
        XCTAssertNil(doc.url)
        XCTAssertEqual(store.activeID, doc.id)
    }
}
