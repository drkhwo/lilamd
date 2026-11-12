import AppKit
import XCTest
@testable import MDEditor

/// macOS conventions (1.3): About, the app menu, Help, Open Recent with a missing file.
/// Background-safe: menus are read, never pressed; alerts are built, never shown; no browser opens.
@MainActor
final class MacConventionsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appending(path: "mac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private func topMenu(_ title: String) throws -> NSMenu {
        try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == title }?.submenu, "\(title) menu")
    }

    private var appMenu: NSMenu {
        get throws { try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu, "app menu") }
    }

    // MARK: About (MAC-1)

    func testAboutOptionsHaveVersionCommitAndLink() throws {
        let options = AboutPanel.options(info: ["CFBundleShortVersionString": "1.0.0", "MDEGitCommit": "abc1234", "CFBundleVersion": "7"])
        XCTAssertEqual(options[.applicationVersion] as? String, "1.0.0 (abc1234)")
        XCTAssertEqual(options[.version] as? String, "", "no second version in parentheses")
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertEqual(credits.string, "https://github.com/drkhwo/lilamd")
        let link = credits.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://github.com/drkhwo/lilamd"))
    }

    /// The real Info.plist of this build has the commit (the build script replaced the placeholder).
    func testAboutOptionsFromThisBuild() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let commit = try XCTUnwrap(info["MDEGitCommit"] as? String)
        XCTAssertFalse(commit.isEmpty)
        XCTAssertNotEqual(commit, "MDE_GIT_COMMIT")
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(AboutPanel.options(info: info)[.applicationVersion] as? String, "\(version) (\(commit))")
    }

    func testAppMenuHasOneAboutItem() throws {
        let about = try appMenu.items.filter { $0.title.hasPrefix("About") }
        XCTAssertEqual(about.map(\.title), ["About LilaMD"])
    }

    // MARK: App menu (MAC-8)

    func testAppMenuHasNoSettingsNoEmptyItemsNoDoubleSeparators() throws {
        // What the user sees: hidden items are not drawn.
        let items = try appMenu.items.filter { !$0.isHidden }
        let titles = items.map(\.title)
        XCTAssertFalse(titles.contains { $0.hasPrefix("Settings") || $0.hasPrefix("Preferences") }, "\(titles)")
        for item in items where !item.isSeparatorItem {
            XCTAssertFalse(item.title.trimmingCharacters(in: .whitespaces).isEmpty, "item with an empty title in \(titles)")
        }
        XCTAssertEqual(items.first?.title, "About LilaMD", "About first, no separator above it: \(titles)")
        XCTAssertEqual(items.last?.isSeparatorItem, false, "\(titles)")
        for (a, b) in zip(items, items.dropFirst()) {
            XCTAssertFalse(a.isSeparatorItem && b.isSeparatorItem, "two separators in a row: \(titles)")
        }
        func all(_ m: NSMenu) -> [NSMenuItem] { m.items + m.items.compactMap(\.submenu).flatMap(all) }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let commaItems = all(menu).filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
        XCTAssertEqual(commaItems.map(\.title), [], "⌘, belongs to Settings, and there is none")
    }

    func testHideDoubleSeparators() {
        let menu = NSMenu()
        for item in [NSMenuItem.separator(), NSMenuItem(title: "A", action: nil, keyEquivalent: ""), .separator(), .separator(),
                     NSMenuItem(title: "B", action: nil, keyEquivalent: "")] { menu.addItem(item) }
        AppMenu.hideDoubleSeparators(menu)
        XCTAssertEqual(menu.items.map(\.isHidden), [true, false, false, true, false])
    }

    // MARK: Help (MAC-9)

    func testHelpMenuHasProjectLinks() throws {
        XCTAssertEqual(AppLinks.repo.absoluteString, "https://github.com/drkhwo/lilamd")
        XCTAssertEqual(AppLinks.issues.absoluteString, "https://github.com/drkhwo/lilamd/issues")
        XCTAssertEqual(AppLinks.help.map(\.title), ["LilaMD on GitHub", "Report an Issue"])
        XCTAssertEqual(AppLinks.help.map(\.url), [AppLinks.repo, AppLinks.issues])
        let help = try topMenu("Help")
        let titles = help.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles.filter { !$0.isEmpty }, ["LilaMD on GitHub", "Report an Issue"], "Help menu: \(titles)")
        XCTAssertFalse(titles.contains("LilaMD Help"))
    }

    // MARK: Open Recent (MAC-6, MAC-7)

    /// MAC-6: a deleted file from Open Recent gives the error alert (built, not shown), no tab and no crash.
    func testOpenRecentDeletedFileShowsAlert() throws {
        let app = try XCTUnwrap(AppDelegate.shared)
        let gone = dir.appending(path: "deleted.md")
        let tabs = app.store.tabs.count
        var alerts: [NSAlert] = []
        app.openRecent(gone, recents: RecentDocuments(source: { [] }), present: { alerts.append($0) })
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.messageText, "The document “deleted.md” could not be opened.")
        XCTAssertFalse((alerts.first?.informativeText ?? "").isEmpty, "a readable reason")
        XCTAssertEqual(app.store.tabs.count, tabs, "no new tab")
    }

    /// MAC-7: a moved file — the old path fails; afterwards the menu has the list the system has now.
    func testOpenRecentMovedFileRefreshesList() throws {
        let app = try XCTUnwrap(AppDelegate.shared)
        let old = dir.appending(path: "moved.md")
        let new = dir.appending(path: "sub/moved.md")
        var system = [old]
        let recents = RecentDocuments(source: { system })
        XCTAssertEqual(recents.urls, [old])
        system = [new] // the system list resolved the bookmark to the new place
        var alerts: [NSAlert] = []
        app.openRecent(old, recents: recents, present: { alerts.append($0) })
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(recents.urls, [new], "list read again after the failed open")
    }

    /// An existing file opens without an alert and the list is not touched.
    func testOpenRecentExistingFileOpensTab() async throws {
        let app = try XCTUnwrap(AppDelegate.shared)
        let url = dir.appending(path: "here.md")
        try Data("Here\n".utf8).write(to: url)
        var system: [URL] = []
        let recents = RecentDocuments(source: { system })
        system = [url]
        var alerts: [NSAlert] = []
        app.openRecent(url, recents: recents, present: { alerts.append($0) })
        XCTAssertEqual(alerts.count, 0)
        XCTAssertEqual(recents.urls, [], "no refresh after a good open")
        let doc = try XCTUnwrap(app.store.tab(for: url))
        await app.store.close(doc.id)
        app.mainWindow.window?.orderOut(nil)
    }

    // MARK: Window drag area (MAC-5)

    func testDoubleClickActionFollowsSystemSetting() throws {
        let suite = "mac-dc-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        // The suite also reads the global domain; set the keys explicitly.
        d.set("Maximize", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(WindowDragArea.doubleClickAction(d), .zoom)
        d.set("Minimize", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(WindowDragArea.doubleClickAction(d), .minimize)
        d.set("None", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(WindowDragArea.doubleClickAction(d), .none)
        d.set("Fill", forKey: "AppleActionOnDoubleClick")
        XCTAssertEqual(WindowDragArea.doubleClickAction(d), .zoom)
    }
}
