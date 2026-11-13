import AppKit
import XCTest
@testable import MDEditor

@MainActor
final class StartScreenLifecycleTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "start-screen-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func file(_ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data("# \(name)\n".utf8).write(to: url)
        return url
    }

    private func history() -> HistoryStore {
        HistoryStore(storageURL: directory.appending(path: "History.json"))
    }

    private func session() -> SessionStore {
        SessionStore(storageURL: directory.appending(path: "Session.json"))
    }

    func testLaunchRoutingUsesDefaultLaunchPreferenceAndIncomingURLs() throws {
        let saved = try file("saved.md")
        let incoming = try file("incoming.md")
        let restorable = RestorableSession(files: [saved], activeFile: saved, missingCount: 1)
        let empty = RestorableSession(files: [], activeFile: nil, missingCount: 0)

        XCTAssertEqual(AppLaunchRouter.destination(isDefaultLaunch: true, incomingURLs: [],
                                                   alwaysReopenTabs: false, session: restorable), .startScreen)
        XCTAssertEqual(AppLaunchRouter.destination(isDefaultLaunch: true, incomingURLs: [],
                                                   alwaysReopenTabs: true, session: restorable), .restore(restorable))
        XCTAssertEqual(AppLaunchRouter.destination(isDefaultLaunch: false, incomingURLs: [],
                                                   alwaysReopenTabs: true, session: restorable), .waitForIncomingFiles)
        XCTAssertEqual(AppLaunchRouter.destination(isDefaultLaunch: false, incomingURLs: [incoming],
                                                   alwaysReopenTabs: true, session: restorable),
                       .openFiles(incoming: [incoming], restoring: restorable))
        XCTAssertEqual(AppLaunchRouter.destination(isDefaultLaunch: true, incomingURLs: [incoming],
                                                   alwaysReopenTabs: false, session: empty),
                       .openFiles(incoming: [incoming], restoring: nil))
    }

    func testEmptyStoreAndLastTabCloseSelectStartScreenContent() async throws {
        let url = try file("only.md")
        let store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false

        XCTAssertEqual(store.contentState, .startScreen)
        let document = try store.open(url)
        XCTAssertEqual(store.contentState, .editor)
        let closed = await store.close(document.id)
        XCTAssertTrue(closed)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertEqual(store.contentState, .startScreen)
    }

    func testRedButtonClosePolicyClosesAfterSuccessfulTabFlowAndKeepsAppRunning() {
        XCTAssertEqual(RedButtonClosePolicy.decision(tabCount: 1, closeFlowInProgress: false), .closeTabs)
        XCTAssertEqual(RedButtonClosePolicy.decision(tabCount: 0, closeFlowInProgress: false), .closeWindow)
        XCTAssertEqual(RedButtonClosePolicy.decision(tabCount: 1, closeFlowInProgress: true), .keepOpen)
        XCTAssertTrue(RedButtonClosePolicy.shouldCloseWindow(afterCloseFlowSucceeded: true))
        XCTAssertFalse(RedButtonClosePolicy.shouldCloseWindow(afterCloseFlowSucceeded: false))
        XCTAssertFalse(AppDelegate(historyStore: history(), sessionStore: session())
            .applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }

    func testDockReopenShowsStartScreenForEmptyStoreAndEditorForExistingTabs() {
        XCTAssertEqual(DockReopenPolicy.destination(hasVisibleWindows: false, hasTabs: false), .showStartScreen)
        XCTAssertEqual(DockReopenPolicy.destination(hasVisibleWindows: false, hasTabs: true), .showEditor)
        XCTAssertEqual(DockReopenPolicy.destination(hasVisibleWindows: true, hasTabs: false), .leaveVisibleWindow)
    }

    func testIncomingFilesBecomeActiveAfterSavedSessionFiles() throws {
        let saved = try file("saved.md")
        let incoming = try file("incoming.md")
        let store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false

        let restored = store.restoreFiles([saved], activeFile: saved)
        XCTAssertEqual(restored.map(\.url), [saved])
        XCTAssertEqual(store.active?.url, saved)
        let incomingDocument = try store.open(incoming)

        XCTAssertEqual(store.tabs.map(\.url), [saved, incoming])
        XCTAssertEqual(store.activeID, incomingDocument.id)
        XCTAssertEqual(store.active?.url, incoming)
    }

    func testStartupWindowAndOpenRecentShareInjectedHistoryStore() throws {
        let history = history()
        let session = session()
        let app = AppDelegate(historyStore: history, sessionStore: session)
        defer { app.mainWindow.window?.close() }
        let url = try file("shared.md")

        XCTAssertTrue(app.store.historyStore === history)
        XCTAssertTrue(app.mainWindow.historyStore === history)
        XCTAssertTrue(app.mainWindow.sessionStore === session)
        history.noteOpen(url)

        let screen = StartScreenPresentation(records: app.mainWindow.historyStore.records, query: "")
        XCTAssertEqual(history.menuRecords, screen.pinned + screen.recent)
        XCTAssertEqual(history.menuRecords.map(\.path), [url.path])
        history.pin(try XCTUnwrap(history.records.first?.id))
        let pinnedScreen = StartScreenPresentation(records: app.mainWindow.historyStore.records, query: "")
        XCTAssertEqual(history.menuRecords.map(\.id), pinnedScreen.pinned.map(\.id) + pinnedScreen.recent.map(\.id))
        XCTAssertTrue(app.mainWindow.historyStore === app.historyStore)
    }
}
