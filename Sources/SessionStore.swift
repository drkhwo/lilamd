import AppKit

struct FileTabSnapshot {
    let files: [URL]
    let activeFile: URL?
}

struct RestorableSession {
    let files: [URL]
    let activeFile: URL?
    let missingCount: Int
}

/// Persists the file-backed part of a tab session and its reopen preference in one JSON file.
@MainActor
final class SessionStore {
    static let fileName = "Session.json"

    private struct FileBookmark: Codable, Equatable {
        var bookmarkData: Data?
        var path: String
    }

    private struct Archive: Codable {
        var files: [FileBookmark]
        var activeFilePath: String?
        var alwaysReopenTabs: Bool
    }

    let storageURL: URL
    private let fileManager: FileManager
    private var files: [FileBookmark] = []
    private var activeFilePath: String?
    private(set) var alwaysReopenTabs = false

    init(storageURL: URL, fileManager: FileManager = .default) {
        self.storageURL = storageURL
        self.fileManager = fileManager
        guard let data = try? Data(contentsOf: storageURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        files = archive.files
        activeFilePath = archive.activeFilePath
        alwaysReopenTabs = archive.alwaysReopenTabs
    }

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

    static func defaultStore(isUnderXCTest: Bool, isDebug: Bool) -> SessionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return SessionStore(storageURL: location(
            isUnderXCTest: isUnderXCTest,
            isDebug: isDebug,
            applicationSupportURL: support
        ))
    }

    func setAlwaysReopenTabs(_ enabled: Bool) {
        guard alwaysReopenTabs != enabled else { return }
        alwaysReopenTabs = enabled
        persist()
    }

    /// A cancelled quit leaves the last successfully saved session untouched.
    func save(_ snapshot: FileTabSnapshot, quitPreparationSucceeded: Bool = true) {
        guard quitPreparationSucceeded else { return }
        files = snapshot.files.map(Self.bookmark)
        activeFilePath = snapshot.activeFile.map(Self.canonical).map(\.path)
        persist()
    }

    var savedFileCount: Int { files.count }

    func restorableSession() -> RestorableSession {
        var resolved: [(bookmark: FileBookmark, url: URL)] = []
        for bookmark in files {
            guard let url = resolve(bookmark), fileManager.fileExists(atPath: url.path) else { continue }
            resolved.append((bookmark, url))
        }
        let active = resolved.first { Self.canonical($0.url).path == activeFilePath }?.url
        return RestorableSession(files: resolved.map(\.url), activeFile: active, missingCount: files.count - resolved.count)
    }

    private func resolve(_ bookmark: FileBookmark) -> URL? {
        if let data = bookmark.bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return Self.canonical(url)
            }
        }
        return Self.canonical(URL(fileURLWithPath: bookmark.path))
    }

    private func persist() {
        let archive = Archive(files: files, activeFilePath: activeFilePath, alwaysReopenTabs: alwaysReopenTabs)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        do {
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            log.error("Could not save session: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func bookmark(_ url: URL) -> FileBookmark {
        let canonical = canonical(url)
        return FileBookmark(
            bookmarkData: try? canonical.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            path: canonical.path
        )
    }

    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}
