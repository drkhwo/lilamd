import XCTest
@testable import MDEditor

@MainActor
final class StartScreenViewTests: XCTestCase {
    private func record(_ name: String, pinned: Bool = false, order: Int? = nil,
                        date: TimeInterval = 0, root: String = "/Users/test/Docs") -> HistoryRecord {
        HistoryRecord(bookmarkData: nil, path: "\(root)/\(name)",
                      lastOpened: Date(timeIntervalSince1970: date), pinned: pinned, pinOrder: order)
    }

    func testEmptyHistoryPresentation() {
        let model = StartScreenPresentation(records: [], query: "")
        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.pinned.isEmpty)
        XCTAssertTrue(model.recent.isEmpty)
        XCTAssertTrue(model.missing.isEmpty)
        XCTAssertTrue(model.matchRanges(in: "Anything").isEmpty)
    }

    func testPinnedAndRecentGroupingDeduplicatesPinnedRecords() {
        let recentOld = record("old.md", date: 1)
        let pinnedLater = record("pinned.md", pinned: true, order: 1, date: 2)
        let pinnedFirst = record("first.md", pinned: true, order: 0, date: 0)
        let model = StartScreenPresentation(records: [recentOld, pinnedLater, pinnedFirst], query: "")

        XCTAssertEqual(model.pinned.map(\.displayName), ["first.md", "pinned.md"])
        XCTAssertEqual(model.recent.map(\.displayName), ["old.md"])
        XCTAssertFalse(model.recent.contains { $0.id == pinnedLater.id })
    }

    func testCaseInsensitiveNameAndPathSearchAndMatchRanges() {
        let model = StartScreenPresentation(records: [
            record("Project-PLAN.md", root: "/Users/test/Work"),
            record("notes.md", root: "/Users/test/Plans")
        ], query: "plan")

        XCTAssertEqual(Set((model.pinned + model.recent).map(\.displayName)), ["Project-PLAN.md", "notes.md"])
        let name = "Project-PLAN.md"
        let ranges = model.matchRanges(in: name)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(name[ranges[0]]), "PLAN")
        XCTAssertEqual(model.matchRanges(in: "no match"), [])
    }

    func testMissingFileStateIsRetainedInPresentation() {
        let present = record("here.md")
        let absent = record("gone.md")
        let model = StartScreenPresentation(records: [present, absent], query: "") { $0.id == present.id }

        XCTAssertTrue(model.exists(present))
        XCTAssertFalse(model.exists(absent))
        XCTAssertEqual(model.missing.map(\.displayName), ["gone.md"])
        XCTAssertEqual(model.recent.count, 2)
    }

    func testRestoreButtonVisibilityAndCount() {
        XCTAssertNil(StartScreenPresentation.restoreButtonTitle(for: RestorableSession(files: [], activeFile: nil, missingCount: 2)))
        let one = RestorableSession(files: [URL(fileURLWithPath: "/one.md")], activeFile: nil, missingCount: 3)
        let two = RestorableSession(files: [URL(fileURLWithPath: "/one.md"), URL(fileURLWithPath: "/two.md")],
                                    activeFile: nil, missingCount: 1)
        XCTAssertEqual(StartScreenPresentation.restoreButtonTitle(for: one), "Restore last session · 1 tab")
        XCTAssertEqual(StartScreenPresentation.restoreButtonTitle(for: two), "Restore last session · 2 tabs")
    }

    func testActionCallbacks() {
        var calls: [String] = []
        let file = URL(fileURLWithPath: "/tmp/file.md")
        let session = RestorableSession(files: [file], activeFile: file, missingCount: 0)
        let actions = StartScreenActions(
            newDocument: { calls.append("new") },
            openDocument: { calls.append("open-panel") },
            restoreSession: { calls.append("restore:\($0.files.count)") },
            openFile: { calls.append("file:\($0.path)") }
        )

        actions.createNew()
        actions.showOpenPanel()
        actions.restore(session)
        actions.open(file)

        XCTAssertEqual(calls, ["new", "open-panel", "restore:1", "file:/tmp/file.md"])
    }
}
