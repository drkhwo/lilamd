import AppKit

/// Owns the single main window and its tabs. Finder, `open -a` and Dock drops arrive here
/// (`application(_:open:)`), so files open as tabs even when the window is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TabStore(prompter: AlertPrompter())
    private(set) lazy var mainWindow = MainWindowController(store: store)

    /// XCTest hosts the app: no Open panel at launch, no Open Recent entries.
    static var isUnderXCTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func applicationWillFinishLaunching(_ notification: Notification) {
        ZoomMenuSupport.install()
        // Our own tab bar: no system window tabs and no system "Show Next Tab" items (they would take ⌃Tab).
        NSWindow.allowsAutomaticWindowTabbing = false
        // Test hook for screenshots (TESTS C8) without changing the system setting:
        // `open -a "LilaMD" file.md --args -MDEditorAppearance dark`.
        switch UserDefaults.standard.string(forKey: "MDEditorAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // Manual runs of a Debug build share the bundle id with the installed app:
        // `--args -MDEditorRecordsRecents NO` keeps their files out of its Open Recent menu.
        let defaults = UserDefaults.standard
        let recents = defaults.object(forKey: "MDEditorRecordsRecents") == nil || defaults.bool(forKey: "MDEditorRecordsRecents")
        store.recordsRecents = recents && !Self.isUnderXCTest
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        mainWindow.open(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without files → Open panel, as with DocumentGroup (P5). Files from Finder or `open -a` may arrive
        // after this call, so "no tabs yet" is not enough: a launch to open documents is not a default launch.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard isDefaultLaunch, store.tabs.isEmpty, !Self.isUnderXCTest else { return }
        openDocument()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if store.tabs.isEmpty { openDocument() } else { mainWindow.show() }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = store.tabs.filter(\.isDirty).count
        log.info("quit requested, \(dirty) tabs with unsaved changes")
        guard dirty > 0 else { return .terminateNow }
        mainWindow.show() // the questions are sheets on this window
        Task {
            let ok = await store.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    func applicationWillResignActive(_ notification: Notification) {
        Task { await store.saveAll(reason: .autosave) }
    }

    // MARK: Menu actions

    /// The main window of the key window (tests create their own), else the app's.
    func targetWindow() -> MainWindowController {
        (NSApp.keyWindow?.windowController as? MainWindowController) ?? mainWindow
    }

    func targetStore() -> TabStore { targetWindow().store }

    func newDocument() {
        let window = targetWindow()
        window.store.newUntitled()
        window.show()
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdownText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let window = targetWindow()
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { window.open(panel.urls) }
        }
    }

    func save() {
        let store = targetStore()
        guard let doc = store.active else { return }
        Task { await store.save(doc, reason: .explicit) }
    }

    func saveAs() {
        let store = targetStore()
        guard let doc = store.active else { return }
        Task {
            guard let target = await store.prompter.chooseSaveURL(for: doc) else { return }
            await store.saveAs(doc, to: target)
        }
    }

    /// The main window closes its active tab; any other window (Settings, an alert's window) just closes.
    func closeTab() {
        if let main = NSApp.keyWindow?.windowController as? MainWindowController {
            main.closeActiveTab()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }
}
