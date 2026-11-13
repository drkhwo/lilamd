import AppKit
import Combine
import SwiftUI

/// The single main window: tab bar + editors. Owned by `AppDelegate` (tests create their own with a fake prompter).
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: TabStore
    let historyStore: HistoryStore
    let sessionStore: SessionStore
    private var subscriptions: Set<AnyCancellable> = []
    private var isClosingAll = false
    private var keyMonitor: Any?

    init(store: TabStore, historyStore: HistoryStore? = nil, sessionStore: SessionStore? = nil,
         openDocument: @escaping () -> Void = {}) {
        self.store = store
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "LilaMD-window-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.historyStore = historyStore ?? store.historyStore ?? HistoryStore(storageURL: temporaryRoot.appending(path: HistoryStore.fileName))
        self.sessionStore = sessionStore ?? SessionStore(storageURL: temporaryRoot.appending(path: SessionStore.fileName))
        let size = MDEditorApp.defaultWindowSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = "LilaMD"
        super.init(window: window)
        let hosting = NSHostingController(rootView: TabbedWindow(
            store: store,
            historyStore: self.historyStore,
            sessionStore: self.sessionStore,
            openFiles: { [weak self] in self?.open($0) },
            openDocument: openDocument,
            restoreSession: { [weak self] in self?.restore($0) }
        ))
        // The window keeps the size set here; the view only reports its minimum (480×320).
        hosting.sizingOptions = [.minSize]
        // The Visual / Source picker in `.toolbar` becomes the window's toolbar.
        hosting.sceneBridgingOptions = [.toolbars]
        window.contentViewController = hosting
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.center()
        window.delegate = self
        (store.prompter as? AlertPrompter)?.window = { [weak window] in window }
        observeStore()
        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        installKeyMonitor()
        TestBackground.activateApp()
        window.makeKeyAndOrderFront(nil)
        TestBackground.park(window)
    }

    /// Restores the saved file tabs, then opens any incoming launch files so the last incoming file is active.
    func restore(_ session: RestorableSession, incomingURLs: [URL] = [],
                 present: (NSAlert) -> Void = { _ = $0.runModal() }) {
        _ = store.restoreFiles(session.files, activeFile: session.activeFile)
        if incomingURLs.isEmpty {
            show()
        } else {
            _ = open(incomingURLs, present: present)
        }
        if session.missingCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Some files could not be restored."
            alert.informativeText = "\(session.missingCount) \(session.missingCount == 1 ? "file" : "files") not found."
            alert.addButton(withTitle: "OK")
            present(alert)
        }
    }

    /// Finder, `open -a`, the Open panel, drops: one tab per file (an open file only gets activated).
    /// `present` shows the error alert of a file that could not be opened; tests capture it instead of `runModal`.
    /// Returns false if any file failed.
    @discardableResult
    func open(_ urls: [URL], present: (NSAlert) -> Void = { _ = $0.runModal() }) -> Bool {
        var failed: [(URL, Error)] = []
        var last: OpenDocument?
        for url in urls {
            // Only the last file becomes active (and gets a web view now); the others wait for their first show.
            do { last = try store.open(url, activate: false) } catch {
                log.error("open failed: \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                failed.append((url, error))
            }
        }
        if let last { store.activate(last.id) }
        if !store.tabs.isEmpty { show() }
        for (url, error) in failed { present(Self.makeOpenErrorAlert(url: url, error: error)) }
        return failed.isEmpty
    }

    /// The text of `MarkdownDocumentError` (TB-21), as DocumentGroup showed it.
    static func makeOpenErrorAlert(url: URL, error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "The document “\(url.lastPathComponent)” could not be opened."
        let reason = (error as? LocalizedError)?.failureReason
        alert.informativeText = [error.localizedDescription, reason].compactMap { $0 }.joined(separator: " ")
        return alert
    }

    /// File > Close Tab (⌘W). Closing the last tab leaves the start screen in this window.
    func closeActiveTab() {
        log.info("closeActiveTab: \(self.store.active?.displayName ?? "no tab", privacy: .public)")
        guard let id = store.activeID else { return }
        Task { await store.close(id) }
    }

    /// ⌃Tab / ⇧⌘] next tab, ⌃⇧Tab / ⇧⌘[ previous, wrapping around (TB-8). Taken before the window sees the key:
    /// SwiftUI gives a menu item one shortcut only, and Vditor's Tab handlers (table cells) ignore Control.
    /// Key codes, not characters: the same keys in every keyboard layout.
    private func switchesTab(_ event: NSEvent) -> Bool {
        guard event.window === window, !store.tabs.isEmpty else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let tab: UInt16 = 48, rightBracket: UInt16 = 30, leftBracket: UInt16 = 33
        if (event.keyCode == tab && flags == .control) || (event.keyCode == rightBracket && flags == [.command, .shift]) {
            store.activateNext()
        } else if (event.keyCode == tab && flags == [.control, .shift]) || (event.keyCode == leftBracket && flags == [.command, .shift]) {
            store.activatePrevious()
        } else {
            return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The red button closes the tabs one by one, then closes this window. Cancel stops the sequence.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch RedButtonClosePolicy.decision(tabCount: store.tabs.count, closeFlowInProgress: isClosingAll) {
        case .closeWindow:
            return true
        case .keepOpen:
            return false
        case .closeTabs:
            isClosingAll = true
            Task {
                defer { isClosingAll = false }
                var closedAllTabs = true
                for doc in store.tabs {
                    guard await store.close(doc.id) else {
                        closedAllTabs = false
                        break
                    }
                }
                guard RedButtonClosePolicy.shouldCloseWindow(afterCloseFlowSucceeded: closedAllTabs) else { return }
                sender.close()
            }
            return false
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.switchesTab(event) == true } ? nil : event
        }
    }

    // MARK: Store → window

    private func observeStore() {
        // Title, proxy icon and the "edited" dot follow the active tab (TB-15).
        store.$activeID
            .map { [store] id -> AnyPublisher<(String, URL?, Bool), Never> in
                guard let doc = id.flatMap(store.document) else {
                    return Just(("LilaMD", nil, false)).eraseToAnyPublisher()
                }
                return doc.$displayName.combineLatest(doc.$url, doc.$isDirty)
                    .map { ($0, $1, $2) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] title, url, dirty in
                guard let window = self?.window else { return }
                window.title = title
                window.representedURL = url
                window.isDocumentEdited = dirty
            }
            .store(in: &subscriptions)
    }
}

enum RedButtonCloseDecision: Equatable {
    case closeWindow
    case closeTabs
    case keepOpen
}

enum RedButtonClosePolicy {
    static func decision(tabCount: Int, closeFlowInProgress: Bool) -> RedButtonCloseDecision {
        if closeFlowInProgress { return .keepOpen }
        return tabCount == 0 ? .closeWindow : .closeTabs
    }

    static func shouldCloseWindow(afterCloseFlowSucceeded: Bool) -> Bool {
        afterCloseFlowSucceeded
    }
}
