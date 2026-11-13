import AppKit
import XCTest
@testable import MDEditor

@MainActor
final class SessionStoreTests: XCTestCase {
    private var directory: URL!
    private var storageURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "session-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appending(path: "nested/Session.json")
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func file(_ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data("# \(name)\n".utf8).write(to: url)
        return url
    }

    private func makeStore(withFiles files: [URL]) throws -> (TabStore, [OpenDocument]) {
        let store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false
        let documents = try files.map { try store.open($0, activate: false) }
        return (store, documents)
    }

    func testOneJSONFileRoundTripAndDefaultPreference() throws {
        let first = try file("first.md")
        let second = try file("second.md")
        let store = SessionStore(storageURL: storageURL)
        XCTAssertFalse(store.alwaysReopenTabs)
        store.save(FileTabSnapshot(files: [first, second], activeFile: first))

        let reopened = SessionStore(storageURL: storageURL)
        let session = reopened.restorableSession()
        XCTAssertEqual(session.files, [first, second])
        XCTAssertEqual(session.activeFile, first)
        XCTAssertEqual(session.missingCount, 0)
        XCTAssertFalse(reopened.alwaysReopenTabs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storageURL.deletingLastPathComponent().path), ["Session.json"])
    }

    func testPreferenceIsDefaultOffAndPersistsInSessionFile() throws {
        let store = SessionStore(storageURL: storageURL)
        XCTAssertFalse(store.alwaysReopenTabs)
        store.setAlwaysReopenTabs(true)

        let reopened = SessionStore(storageURL: storageURL)
        XCTAssertTrue(reopened.alwaysReopenTabs)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any])
        XCTAssertEqual(json["alwaysReopenTabs"] as? Bool, true)
    }

    func testTabStoreSnapshotPreservesFileOrderAndActiveIdentity() throws {
        let urls = try [file("a.md"), file("b.md"), file("c.md")]
        let (store, docs) = try makeStore(withFiles: urls)
        store.activate(docs[1].id)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        let snapshot = store.fileSessionSnapshot()
        XCTAssertEqual(snapshot.files, [urls[1], urls[2], urls[0]])
        XCTAssertEqual(snapshot.activeFile, urls[1])
    }

    func testSnapshotExcludesUntitledTabs() throws {
        let url = try file("saved.md")
        let (store, docs) = try makeStore(withFiles: [url])
        let untitled = store.newUntitled()
        store.activate(untitled.id)

        let snapshot = store.fileSessionSnapshot()
        XCTAssertEqual(snapshot.files, [url])
        XCTAssertNil(snapshot.activeFile)
        XCTAssertEqual(docs.count, 1)
    }

    func testRestoreFiltersMissingFilesAndFallsBackToLastSurvivor() throws {
        let first = try file("first.md")
        let missing = directory.appending(path: "missing.md")
        let last = try file("last.md")
        let session = SessionStore(storageURL: storageURL)
        session.save(FileTabSnapshot(files: [first, missing, last], activeFile: missing))

        let restored = session.restorableSession()
        XCTAssertEqual(restored.files, [first, last])
        XCTAssertNil(restored.activeFile)
        XCTAssertEqual(restored.missingCount, 1)

        let (store, _) = try makeStore(withFiles: [])
        let restoredTabs = store.restoreFiles(restored.files, activeFile: restored.activeFile)
        XCTAssertEqual(restoredTabs.map(\.url), [first, last])
        XCTAssertEqual(store.active?.url, last)
        XCTAssertEqual(store.tabs.map(\.url), [first, last])
    }

    func testRestoreKeepsSavedActiveFileWhenItSurvives() throws {
        let first = try file("first.md")
        let second = try file("second.md")
        let (store, docs) = try makeStore(withFiles: [first, second])
        let snapshot = store.fileSessionSnapshot()
        let restoredStore = TabStore(prompter: FakePrompter())
        restoredStore.recordsRecents = false

        let restored = restoredStore.restoreFiles(snapshot.files, activeFile: snapshot.activeFile)
        XCTAssertEqual(restored.map(\.url), [first, second])
        XCTAssertEqual(restoredStore.active?.url, second)
        XCTAssertEqual(restoredStore.activeID, restored[1].id)
        XCTAssertEqual(docs.count, 2)
    }

    func testCancelledQuitSnapshotDoesNotReplaceLastSavedSession() throws {
        let previous = try file("previous.md")
        let cancelled = try file("cancelled.md")
        let store = SessionStore(storageURL: storageURL)
        store.save(FileTabSnapshot(files: [previous], activeFile: previous))
        store.save(FileTabSnapshot(files: [cancelled], activeFile: cancelled), quitPreparationSucceeded: false)

        let reopened = SessionStore(storageURL: storageURL)
        XCTAssertEqual(reopened.restorableSession().files, [previous])
        XCTAssertEqual(reopened.restorableSession().activeFile, previous)
    }

    func testInjectedStorageAndRuntimeLocationsAreIsolated() throws {
        let store = SessionStore(storageURL: storageURL)
        let saved = try file("isolated.md")
        store.save(FileTabSnapshot(files: [saved], activeFile: saved))
        XCTAssertEqual(store.storageURL, storageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))

        let support = directory.appending(path: "Application Support", directoryHint: .isDirectory)
        let debugURL = SessionStore.location(isUnderXCTest: false, isDebug: true, applicationSupportURL: support)
        let releaseURL = SessionStore.location(isUnderXCTest: false, isDebug: false, applicationSupportURL: support)
        let testURL1 = SessionStore.location(isUnderXCTest: true, isDebug: true, applicationSupportURL: support, temporaryDirectory: directory)
        let testURL2 = SessionStore.location(isUnderXCTest: true, isDebug: true, applicationSupportURL: support, temporaryDirectory: directory)

        XCTAssertNotEqual(debugURL, releaseURL)
        XCTAssertNotEqual(testURL1, releaseURL)
        XCTAssertNotEqual(testURL1, testURL2)
        XCTAssertTrue(testURL1.path.hasPrefix(directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseURL.path))
    }
}
