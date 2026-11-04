import AppKit
import Combine
import SwiftUI

/// The single main window: tab bar + editors. Owned by `AppDelegate` (tests create their own with a fake prompter).
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: TabStore
    private var subscriptions: Set<AnyCancellable> = []
    /// The red button is closing the tabs one by one.
    private var isClosingAll = false
    private var keyMonitor: Any?

    init(store: TabStore) {
        self.store = store
        let size = MDEditorApp.defaultWindowSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = "LilaMD"
        super.init(window: window)
        let hosting = NSHostingController(rootView: TabbedWindow(store: store, openFiles: { [weak self] in self?.open($0) }))
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.switchesTab(event) == true } ? nil : event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Finder, `open -a`, the Open panel, drops: one tab per file (an open file only gets activated).
    func open(_ urls: [URL]) {
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
        for (url, error) in failed { Self.makeOpenErrorAlert(url: url, error: error).runModal() }
    }

    /// The text of `MarkdownDocumentError` (TB-21), as DocumentGroup showed it.
    static func makeOpenErrorAlert(url: URL, error: Error) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "The document “\(url.lastPathComponent)” could not be opened."
        let reason = (error as? LocalizedError)?.failureReason
        alert.informativeText = [error.localizedDescription, reason].compactMap { $0 }.joined(separator: " ")
        return alert
    }

    /// File > Close Tab (⌘W). No tabs: the window just goes away.
    func closeActiveTab() {
        guard let id = store.activeID else {
            window?.orderOut(nil)
            return
        }
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

    /// Only tests close the window for real (the app hides it).
    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The red button closes the tabs one by one, like ⌘W on each; Cancel in any question stops.
    /// The window itself is only hidden (when the last tab is gone), never closed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isClosingAll else { return false }
        isClosingAll = true
        Task {
            defer { isClosingAll = false }
            for doc in store.tabs {
                guard await store.close(doc.id) else { return }
            }
        }
        return false
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
        // Last tab closed → hide the window; the app keeps running (TB-12).
        store.$order
            .sink { [weak self] order in
                if order.isEmpty { self?.window?.orderOut(nil) }
            }
            .store(in: &subscriptions)
    }
}
