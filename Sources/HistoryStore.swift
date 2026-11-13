import AppKit

struct HistoryRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var bookmarkData: Data?
    var path: String
    var lastOpened: Date
    var pinned: Bool
    var pinOrder: Int?

    var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
    var directoryPath: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }

    init(id: UUID = UUID(), bookmarkData: Data?, path: String, lastOpened: Date, pinned: Bool = false, pinOrder: Int? = nil) {
        self.id = id
        self.bookmarkData = bookmarkData
        self.path = path
        self.lastOpened = lastOpened
        self.pinned = pinned
        self.pinOrder = pinOrder
    }
}

/// Persistent recent files. The storage URL is explicit so Debug and tests cannot share Release data.
@MainActor
final class HistoryStore: ObservableObject {
    static let unpinnedLimit = 50
    static let fileName = "History.json"

    @Published private(set) var records: [HistoryRecord] = []
    let storageURL: URL
    private let fileManager: FileManager
    private var migrationCompleted = false

    private struct Archive: Codable {
        var records: [HistoryRecord]
        var migrationCompleted: Bool
    }

    init(storageURL: URL, fileManager: FileManager = .default, migrationSource: () -> [URL] = { [] }) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        if let data = try? Data(contentsOf: storageURL), let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            records = Self.ordered(archive.records)
            migrationCompleted = archive.migrationCompleted
        }
        guard !migrationCompleted else { return }
        let urls = migrationSource()
        for (index, url) in urls.enumerated() {
            let date = Date(timeIntervalSince1970: TimeInterval(urls.count - index))
            if matchingRecord(for: url) == nil {
                records.append(makeRecord(url, date: date))
            }
        }
        trimRecents()
        // Keep migration retryable if the atomic write fails.
        if persist(migrationCompleted: true) { migrationCompleted = true }
    }

    /// The selected URL is a file, never the installed app's data during Debug or XCTest.
    static func location(
        isUnderXCTest: Bool,
        isDebug: Bool,
        applicationSupportURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        if isUnderXCTest {
            return temporaryDirectory.appending(path: "LilaMD-tests-\(UUID().uuidString)").appending(path: fileName)
        }
        let directory = applicationSupportURL.appending(path: isDebug ? "LilaMD-Debug" : "LilaMD", directoryHint: .isDirectory)
        return directory.appending(path: fileName)
    }

    static func defaultStore(isUnderXCTest: Bool, isDebug: Bool) -> HistoryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = location(isUnderXCTest: isUnderXCTest, isDebug: isDebug, applicationSupportURL: support)
        let source: () -> [URL] = isUnderXCTest ? { [] } : { NSDocumentController.shared.recentDocumentURLs }
        return HistoryStore(storageURL: url, migrationSource: source)
    }

    var pinned: [HistoryRecord] { Self.ordered(records).filter(\.pinned) }
    var recent: [HistoryRecord] { Self.ordered(records).filter { !$0.pinned } }

    func noteOpen(_ url: URL, at date: Date = Date()) {
        let canonicalURL = Self.canonical(url)
        if let index = records.firstIndex(where: { Self.canonical(self.url(for: $0)) == canonicalURL }) {
            records[index].path = canonicalURL.path
            records[index].bookmarkData = Self.bookmark(for: canonicalURL) ?? records[index].bookmarkData
            records[index].lastOpened = date
        } else {
            records.append(makeRecord(url, date: date))
        }
        trimRecents()
        save()
    }

    func pin(_ id: HistoryRecord.ID) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].pinned else { return }
        records[index].pinned = true
        records[index].pinOrder = (records.compactMap(\.pinOrder).max() ?? -1) + 1
        trimRecents()
        save()
    }

    func unpin(_ id: HistoryRecord.ID) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].pinned else { return }
        records[index].pinned = false
        records[index].pinOrder = nil
        normalizePinOrder()
        trimRecents()
        save()
    }

    func remove(_ id: HistoryRecord.ID) {
        guard records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        normalizePinOrder()
        save()
    }

    func removeRecent(_ id: HistoryRecord.ID) {
        guard records.contains(where: { $0.id == id && !$0.pinned }) else { return }
        remove(id)
    }

    func clearRecents() {
        records.removeAll { !$0.pinned }
        save()
    }

    func url(for record: HistoryRecord) -> URL {
        if let data = record.bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return Self.canonical(resolved)
            }
        }
        return Self.canonical(URL(fileURLWithPath: record.path))
    }

    func fileExists(_ record: HistoryRecord) -> Bool {
        fileManager.fileExists(atPath: url(for: record).path)
    }

    private func matchingRecord(for url: URL) -> HistoryRecord? {
        let path = Self.canonical(url).path
        return records.first { Self.canonical(self.url(for: $0)).path == path }
    }

    private func makeRecord(_ url: URL, date: Date) -> HistoryRecord {
        let canonicalURL = Self.canonical(url)
        return HistoryRecord(bookmarkData: Self.bookmark(for: canonicalURL), path: canonicalURL.path, lastOpened: date)
    }

    private static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private func trimRecents() {
        let recents = Self.ordered(records).filter { !$0.pinned }
        let overflow = Set(recents.dropFirst(Self.unpinnedLimit).map(\.id))
        records.removeAll { overflow.contains($0.id) }
    }

    private func normalizePinOrder() {
        for (order, record) in pinned.enumerated() {
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index].pinOrder = order }
        }
    }

    private static func ordered(_ records: [HistoryRecord]) -> [HistoryRecord] {
        records.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.pinned, $0.pinOrder != $1.pinOrder { return ($0.pinOrder ?? .max) < ($1.pinOrder ?? .max) }
            if $0.lastOpened != $1.lastOpened { return $0.lastOpened > $1.lastOpened }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func save() {
        if !persist(migrationCompleted: migrationCompleted) {
            NSLog("HistoryStore could not save history at %@", storageURL.path)
        }
    }

    @discardableResult
    private func persist(migrationCompleted: Bool) -> Bool {
        do {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let archive = Archive(records: Self.ordered(records), migrationCompleted: migrationCompleted)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(archive).write(to: storageURL, options: .atomic)
            return true
        } catch {
            NSLog("HistoryStore write failed: %@", String(describing: error))
            return false
        }
    }
}
