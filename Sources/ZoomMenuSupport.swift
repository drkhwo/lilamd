import AppKit
import WebKit

@MainActor
enum ZoomMenuSupport {
    private enum MonitorDecision: Sendable { case pass, swallow }

    private final class EventBox: @unchecked Sendable {
        let event: NSEvent
        init(_ event: NSEvent) { self.event = event }
    }

    private static var keyMonitor: Any?
    private static var defaultsObserver: NSObjectProtocol?
    private static var menuObserver: NSObjectProtocol?

    static func install() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let box = EventBox(event)
            let decision = MainActor.assumeIsolated { forwardColumnShortcut(box) }
            return decision == .swallow ? nil : event
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { _ in
            MainActor.assumeIsolated { refreshZoomItems() }
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { refreshZoomItems() }
        }
        refreshZoomItems()
    }

    static func refreshZoomItems() {
        guard let menu = NSApp.mainMenu else { return }
        let zoom = ZoomPreference.load()
        for item in allItems(in: menu) {
            if item.title == "Zoom In" { item.isEnabled = ZoomPreference.next(after: zoom) != nil }
            if item.title == "Zoom Out" { item.isEnabled = ZoomPreference.previous(before: zoom) != nil }
        }
    }

    private static func forwardColumnShortcut(_ box: EventBox) -> MonitorDecision {
        let event = box.event
        guard event.type == .keyDown else { return .pass }
        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard relevantFlags == [.command, .shift], event.keyCode == 24 || event.keyCode == 27,
              let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder as? NSView else { return .pass }

        if let webView = firstResponder as? WKWebView {
            webView.keyDown(with: event)
            return .swallow
        }
        var responder = firstResponder
        while let parent = responder.superview {
            if let webView = parent as? WKWebView {
                webView.keyDown(with: event)
                return .swallow
            }
            responder = parent
        }
        return .pass
    }

    private static func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items + menu.items.flatMap { item in item.submenu.map(allItems(in:)) ?? [] }
    }
}
