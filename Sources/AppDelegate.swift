import AppKit

/// Owns the single main window and its tabs. Finder, `open -a` and Dock drops arrive here
/// (`application(_:open:)`), so files open as tabs even when the window is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let injectedHistoryStore: HistoryStore?
    private let injectedSessionStore: SessionStore?
    private var pendingIncomingURLs: [URL] = []
    private var startupFinished = false
    private var waitingForLaunchURLs = false

    private(set) lazy var historyStore = injectedHistoryStore ?? HistoryStore.defaultStore(isUnderXCTest: Self.isUnderXCTest, isDebug: Self.isDebugBuild)
    private(set) lazy var sessionStore = injectedSessionStore ?? SessionStore.defaultStore(isUnderXCTest: Self.isUnderXCTest, isDebug: Self.isDebugBuild)
    lazy var store = TabStore(prompter: AlertPrompter(), historyStore: historyStore)
    private(set) lazy var mainWindow = MainWindowController(
        store: store,
        historyStore: historyStore,
        sessionStore: sessionStore,
        openDocument: { [weak self] in self?.openDocument() }
    )

    /// The running delegate. `@NSApplicationDelegateAdaptor` hides it behind a SwiftUI proxy; tests need it.
    private(set) static weak var shared: AppDelegate?

    override convenience init() {
        self.init(historyStore: nil, sessionStore: nil)
    }

    init(historyStore: HistoryStore?, sessionStore: SessionStore?) {
        injectedHistoryStore = historyStore
        injectedSessionStore = sessionStore
        super.init()
    }

    /// XCTest hosts the app: no Open panel at launch, no Open Recent entries.
    static var isUnderXCTest: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

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
        _ = historyStore
        _ = sessionStore
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard startupFinished else {
            pendingIncomingURLs.append(contentsOf: urls)
            return
        }
        openIncomingURLs(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TestBackground.returnFocus()
        AppMenu.install()
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard !Self.isUnderXCTest else {
            startupFinished = true
            pendingIncomingURLs.removeAll()
            return
        }
        // Let open-URL callbacks delivered with finish-launch join this batch before choosing a destination.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishStartup(isDefaultLaunch: isDefaultLaunch)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        switch DockReopenPolicy.destination(hasVisibleWindows: flag, hasTabs: !store.tabs.isEmpty) {
        case .leaveVisibleWindow:
            return true
        case .showStartScreen, .showEditor:
            mainWindow.show()
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Tabs with a file are written without a question; only Untitled with text (or a failed write) asks.
    /// Every tab goes through `prepareToQuit`: a big file may still have keys the page has not posted.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = store.tabs.filter(\.isDirty).count
        log.info("quit requested, \(dirty) tabs with unsaved changes")
        guard !store.tabs.isEmpty else {
            sessionStore.save(store.fileSessionSnapshot())
            return .terminateNow
        }
        mainWindow.show() // a question is a sheet on this window
        Task {
            let ok = await store.prepareToQuit()
            sessionStore.save(store.fileSessionSnapshot(), quitPreparationSucceeded: ok)
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

    /// File ▸ Open Recent. A deleted or moved file shows the open error and keeps its history record.
    func openRecent(_ url: URL, present: (NSAlert) -> Void = { _ = $0.runModal() }) {
        _ = targetWindow().open([url], present: present)
    }

    private func finishStartup(isDefaultLaunch: Bool) {
        let incoming = pendingIncomingURLs
        pendingIncomingURLs.removeAll()
        let shouldRestore = sessionStore.alwaysReopenTabs
        let session = shouldRestore ? sessionStore.restorableSession() : RestorableSession(files: [], activeFile: nil, missingCount: 0)
        let route = AppLaunchRouter.destination(
            isDefaultLaunch: isDefaultLaunch,
            incomingURLs: incoming,
            alwaysReopenTabs: shouldRestore,
            session: session
        )
        startupFinished = true

        switch route {
        case .waitForIncomingFiles:
            waitingForLaunchURLs = true
        case .startScreen:
            mainWindow.show()
        case .restore(let savedSession):
            mainWindow.restore(savedSession)
        case .openFiles(let urls, let savedSession):
            if let savedSession {
                mainWindow.restore(savedSession, incomingURLs: urls)
            } else {
                _ = mainWindow.open(urls)
            }
        }
    }

    private func openIncomingURLs(_ urls: [URL]) {
        guard waitingForLaunchURLs else {
            _ = mainWindow.open(urls)
            return
        }
        waitingForLaunchURLs = false
        if sessionStore.alwaysReopenTabs {
            mainWindow.restore(sessionStore.restorableSession(), incomingURLs: urls)
        } else {
            _ = mainWindow.open(urls)
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

enum AppLaunchRoute: Equatable {
    case waitForIncomingFiles
    case startScreen
    case restore(RestorableSession)
    case openFiles(incoming: [URL], restoring: RestorableSession?)
}

enum AppLaunchRouter {
    static func destination(isDefaultLaunch: Bool, incomingURLs: [URL], alwaysReopenTabs: Bool,
                            session: RestorableSession) -> AppLaunchRoute {
        if !incomingURLs.isEmpty {
            return .openFiles(incoming: incomingURLs, restoring: alwaysReopenTabs ? session : nil)
        }
        guard isDefaultLaunch else { return .waitForIncomingFiles }
        if alwaysReopenTabs && (!session.files.isEmpty || session.missingCount > 0) {
            return .restore(session)
        }
        return .startScreen
    }
}

enum DockReopenDestination: Equatable {
    case leaveVisibleWindow
    case showStartScreen
    case showEditor
}

enum DockReopenPolicy {
    static func destination(hasVisibleWindows: Bool, hasTabs: Bool) -> DockReopenDestination {
        if hasVisibleWindows { return .leaveVisibleWindow }
        return hasTabs ? .showEditor : .showStartScreen
    }
}
