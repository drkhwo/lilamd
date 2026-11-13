import AppKit
import XCTest
@testable import MDEditor

@MainActor
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var storageURL: URL!
    private var store: HistoryStore!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appending(path: "nested/History.json")
        store = HistoryStore(storageURL: storageURL)
    }

    override func tearDown() async throws {
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func file(_ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data(name.utf8).write(to: url)
        return url
    }

    func testInsertUpdateAndDeduplication() throws {
        let url = try file("notes.md")
        let first = Date(timeIntervalSince1970: 100)
        store.noteOpen(url, at: first)
        let id = try XCTUnwrap(store.recent.first?.id)

        store.noteOpen(directory.appending(path: "sub/../notes.md"), at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.recent.first?.id, id)
        XCTAssertEqual(store.recent.first?.lastOpened, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.recent.first?.path, directory.appending(path: "notes.md").path)
    }

    func testPinAndUnpinPreservePinOrder() throws {
        let a = try file("a.md")
        let b = try file("b.md")
        let c = try file("c.md")
        store.noteOpen(a, at: Date(timeIntervalSince1970: 100))
        store.noteOpen(b, at: Date(timeIntervalSince1970: 200))
        store.noteOpen(c, at: Date(timeIntervalSince1970: 300))
        let ids = Dictionary(uniqueKeysWithValues: store.records.map { ($0.displayName, $0.id) })

        store.pin(ids["b.md"]!)
        store.pin(ids["a.md"]!)
        store.noteOpen(b, at: Date(timeIntervalSince1970: 400))

        XCTAssertEqual(store.pinned.map(\.displayName), ["b.md", "a.md"])
        XCTAssertEqual(store.pinned.map(\.pinOrder), [0, 1])
        store.unpin(ids["b.md"]!)
        XCTAssertEqual(store.pinned.map(\.displayName), ["a.md"])
        XCTAssertEqual(store.pinned.first?.pinOrder, 0)
        XCTAssertEqual(store.recent.map(\.displayName), ["b.md", "c.md"])
    }

    func testFiftyRecentLimitDoesNotCountPinnedRecords() {
        for index in 0..<3 {
            store.noteOpen(directory.appending(path: "file-\(index).md"), at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let idsByName = Dictionary(uniqueKeysWithValues: store.records.map { ($0.displayName, $0.id) })
        for index in 0..<3 { store.pin(idsByName["file-\(index).md"]!) }
        for index in 3..<55 {
            store.noteOpen(directory.appending(path: "file-\(index).md"), at: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        XCTAssertEqual(store.recent.count, 50)
        XCTAssertEqual(store.pinned.count, 3)
        XCTAssertEqual(store.records.count, 53)
        XCTAssertFalse(store.records.contains { $0.displayName == "file-3.md" })
        XCTAssertTrue(store.records.contains { $0.displayName == "file-52.md" })
    }

    func testRemoveRecentAndClearPreservePins() throws {
        let pinnedURL = try file("pinned.md")
        let recentURL = try file("recent.md")
        store.noteOpen(pinnedURL)
        store.noteOpen(recentURL)
        let pinnedID = try XCTUnwrap(store.records.first { $0.displayName == "pinned.md" }?.id)
        let recentID = try XCTUnwrap(store.records.first { $0.displayName == "recent.md" }?.id)
        store.pin(pinnedID)

        store.removeRecent(pinnedID)
        XCTAssertEqual(store.pinned.map(\.id), [pinnedID])
        store.removeRecent(recentID)
        XCTAssertTrue(store.recent.isEmpty)
        store.noteOpen(recentURL)
        store.clearRecents()

        XCTAssertEqual(store.pinned.map(\.id), [pinnedID])
        XCTAssertTrue(store.recent.isEmpty)
    }

    func testJSONRoundTripPreservesBookmarksDatesAndPinOrder() throws {
        let a = try file("a.md")
        let b = try file("b.md")
        store.noteOpen(a, at: Date(timeIntervalSince1970: 123))
        store.noteOpen(b, at: Date(timeIntervalSince1970: 456))
        let bID = try XCTUnwrap(store.records.first { $0.displayName == "b.md" }?.id)
        store.pin(bID)
        let before = store.records

        let reopened = HistoryStore(storageURL: storageURL)

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: reopened.records.map { ($0.id, $0) }),
            Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertEqual(
            reopened.url(for: try XCTUnwrap(reopened.records.first { $0.displayName == "a.md" })),
            a.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testMissingBookmarkRetainsLastKnownPath() throws {
        let missing = directory.appending(path: "gone/missing.md")
        let record = HistoryRecord(bookmarkData: Data([0]), path: missing.path, lastOpened: Date(timeIntervalSince1970: 987))
        let recordObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let archive: [String: Any] = ["migrationCompleted": true, "records": [recordObject]]
        let data = try JSONSerialization.data(withJSONObject: archive)
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL)
        let reopened = HistoryStore(storageURL: storageURL)
        let retained = try XCTUnwrap(reopened.recent.first)

        XCTAssertEqual(retained.bookmarkData, Data([0]))
        XCTAssertEqual(retained.path, missing.path)
        XCTAssertEqual(retained.displayName, "missing.md")
        XCTAssertEqual(retained.lastOpened, Date(timeIntervalSince1970: 987))
        XCTAssertFalse(reopened.fileExists(retained))
    }

    func testMigrationIsIdempotentAndDoesNotReorderCuratedHistory() throws {
        let migrationURL = directory.appending(path: "migration/History.json")
        let a = directory.appending(path: "a.md")
        let b = directory.appending(path: "b.md")
        var sourceCalls = 0
        let first = HistoryStore(storageURL: migrationURL, migrationSource: {
            sourceCalls += 1
            return [a, b]
        })
        let savedOrder = first.recent.map(\.path)
        let second = HistoryStore(storageURL: migrationURL, migrationSource: {
            sourceCalls += 1
            return [directory.appending(path: "new.md")]
        })

        XCTAssertEqual(sourceCalls, 1)
        XCTAssertEqual(second.recent.map(\.path), savedOrder)
        XCTAssertFalse(second.records.contains { $0.path.hasSuffix("new.md") })
    }

    func testMigrationKeepsOnlyNewestFiftyRecords() {
        let urls = (0..<55).map { directory.appending(path: "migrated-\($0).md") }
        let migrated = HistoryStore(storageURL: directory.appending(path: "migration-cap/History.json"), migrationSource: { urls })

        XCTAssertEqual(migrated.recent.count, 50)
        XCTAssertEqual(migrated.recent.first?.displayName, "migrated-0.md")
        XCTAssertEqual(migrated.recent.last?.displayName, "migrated-49.md")
        XCTAssertFalse(migrated.records.contains { $0.displayName == "migrated-54.md" })
    }

    func testInjectedStorageAndRuntimeLocationsAreIsolated() {
        store.noteOpen(directory.appending(path: "only-here.md"))
        XCTAssertEqual(store.storageURL, storageURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))

        let support = directory.appending(path: "Application Support", directoryHint: .isDirectory)
        let debugURL = HistoryStore.location(isUnderXCTest: false, isDebug: true, applicationSupportURL: support)
        let releaseURL = HistoryStore.location(isUnderXCTest: false, isDebug: false, applicationSupportURL: support)
        let testURL1 = HistoryStore.location(isUnderXCTest: true, isDebug: true, applicationSupportURL: support, temporaryDirectory: directory)
        let testURL2 = HistoryStore.location(isUnderXCTest: true, isDebug: true, applicationSupportURL: support, temporaryDirectory: directory)

        XCTAssertNotEqual(debugURL, releaseURL)
        XCTAssertNotEqual(testURL1, releaseURL)
        XCTAssertNotEqual(testURL1, testURL2)
        XCTAssertTrue(testURL1.path.hasPrefix(directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseURL.path))
    }
}
