import AppKit

/// Owns the single main window and its tabs. Finder, `open -a` and Dock drops arrive here
/// (`application(_:open:)`), so files open as tabs even when the window is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TabStore(prompter: AlertPrompter())
    private(set) lazy var mainWindow = MainWindowController(store: store)

    /// The running delegate. `@NSApplicationDelegateAdaptor` hides it behind a SwiftUI proxy; tests need it.
    private(set) static weak var shared: AppDelegate?

    /// XCTest hosts the app: no Open panel at launch, no Open Recent entries.
    static var isUnderXCTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        TestBackground.prepare()
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
        TestBackground.returnFocus()
        AppMenu.install()
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

    /// Tabs with a file are written without a question; only Untitled with text (or a failed write) asks.
    /// Every tab goes through `prepareToQuit`: a big file may still have keys the page has not posted.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = store.tabs.filter(\.isDirty).count
        log.info("quit requested, \(dirty) tabs with unsaved changes")
        guard !store.tabs.isEmpty else { return .terminateNow }
        mainWindow.show() // a question is a sheet on this window
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

    /// File ▸ Open Recent. A deleted or moved file: the error alert, no new tab, and the menu reads the
    /// system list again (a moved file may resolve to its new path there).
    func openRecent(_ url: URL, recents: RecentDocuments? = nil, present: (NSAlert) -> Void = { _ = $0.runModal() }) {
        guard !targetWindow().open([url], present: present) else { return }
        (recents ?? RecentDocuments.shared).refresh()
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

    enum CloseTarget {
        case tab(MainWindowController)
        case window(NSWindow)
    }

    /// File ▸ Close Tab: the key main window closes its active tab; any other key window (a panel, an alert's
    /// window) just closes; no key window (the item pressed through AX or VoiceOver, or right after the app
    /// became active again) → the app's main window, like every other menu action (`targetWindow`).
    static func closeTarget(keyWindow: NSWindow?, fallback: MainWindowController) -> CloseTarget {
        guard let keyWindow else { return .tab(fallback) }
        if let main = keyWindow.windowController as? MainWindowController { return .tab(main) }
        return .window(keyWindow)
    }

    /// File ▸ Close Tab (⌘W). Target: `closeTarget`.
    func closeTab() {
        let key = NSApp.keyWindow
        log.info("closeTab: keyWindow=\(key.map { String(describing: type(of: $0.windowController ?? $0)) } ?? "nil", privacy: .public) isActive=\(NSApp.isActive, privacy: .public)")
        switch Self.closeTarget(keyWindow: key, fallback: mainWindow) {
        case .tab(let main): main.closeActiveTab()
        case .window(let window): window.performClose(nil)
        }
    }
}
