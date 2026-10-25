import AppKit
import WebKit

/// Owns the WKWebView with Vditor and keeps the document text in sync with it.
@MainActor
final class EditorController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let schemeHandler: SchemeHandler

    /// Document text as represented by the editor right now (exact file characters).
    private(set) var text: String
    private(set) var mode: EditorMode
    private(set) var isReady = false
    private var preserver: SourcePreserver?
    private var appearanceObservation: NSKeyValueObservation?

    /// Called when the user changed the document in the editor.
    var onTextChange: ((String) -> Void)?
    /// Opens a link outside the app (replaced in tests).
    var openExternally: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Every request the page made: scheme requests, blocked (CSP) requests, refused navigations.
    private(set) var requestLog: [String] = []
    private(set) var latencies: [Double] = []
    /// Per-character editor work: from the moment the page sees the keydown to input handled (no queueing).
    private(set) var processing: [Double] = []
    var onReady: (() -> Void)?

    init(text: String, mode: EditorMode, documentDirectory: URL?) {
        self.text = text
        self.mode = mode
        schemeHandler = SchemeHandler(documentDirectory: documentDirectory)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: SchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        // WKWebView's default user agent has no "Safari" token, so Vditor would take its Chrome code paths
        // (e.g. snapshotting the whole document on every keydown). Identify as the WebKit it is.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // Inline predictive text runs candidate generation on the UI thread while typing (latency spikes).
        config.allowsInlinePredictions = false
        let proxy = WeakMessageHandler()
        config.userContentController.add(proxy, name: "mdedit")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        proxy.target = self
        schemeHandler.onRequest = { [weak self] url, status in
            self?.requestLog.append("scheme \(status) \(url.absoluteString)")
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyTheme() }
        }
        webView.load(URLRequest(url: URL(string: "mdedit://app/web/index.html")!))
    }

    var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: Public API

    /// Replace the editor content with `newText` (external change, revert, menu undo).
    func load(text newText: String) {
        guard newText != text else { return }
        log.info("editor reloaded: document changed outside the editor (\(newText.utf8.count) bytes)")
        text = newText
        preserver = nil
        guard isReady else { return }
        call("mdeditor.setValue(value)", ["value": SourcePreserver.editorText(for: newText)])
    }

    func setMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        mode = newMode
        guard isReady else { return }
        preserver = nil
        call("mdeditor.setMode(mode, value)", ["mode": newMode.rawValue, "value": SourcePreserver.editorText(for: text)])
    }

    /// Edit > Undo / Redo (and Cmd+Z / Cmd+Shift+Z, which the menu receives before the page does)
    /// go to Vditor's own history, so the menu and the editor never disagree.
    func undo() { call("mdeditor.undo()", [:]) }
    func redo() { call("mdeditor.redo()", [:]) }

    /// The editor of the key window (or, if the app is not active, the frontmost window with an editor).
    static func forKeyWindow() -> EditorController? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows where window.isVisible {
            if let controller = editor(in: window) { return controller }
        }
        return nil
    }

    private static func editor(in window: NSWindow) -> EditorController? {
        guard let root = window.contentView else { return nil }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let web = view as? WKWebView, let controller = web.navigationDelegate as? EditorController { return controller }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    func setDocumentDirectory(_ url: URL?) { schemeHandler.documentDirectory = url }

    func applyTheme() {
        guard isReady else { return }
        call("mdeditor.setTheme(dark)", ["dark": isDark])
    }

    @discardableResult
    func evaluate(_ js: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(js, arguments: arguments, contentWorld: .page)
    }

    private func call(_ js: String, _ args: [String: Any]) {
        webView.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
            if case let .failure(error) = result { log.error("js call failed: \(String(describing: error), privacy: .public)") }
        }
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "loaded":
            call("mdeditor.init(opts)", ["opts": ["value": SourcePreserver.editorText(for: text),
                                                  "mode": mode.rawValue, "dark": isDark] as [String: Any]])
        case "ready":
            guard let baseline = body["baseline"] as? String else { return }
            let readyMode = (body["mode"] as? String).flatMap(EditorMode.init(rawValue:))
            if let readyMode, readyMode != mode { return } // stale instance
            preserver = SourcePreserver(original: text, baseline: baseline)
            isReady = true
            focusWhenInWindow()
            log.info("editor ready, mode \(self.mode.rawValue, privacy: .public)")
            onReady?()
        case "input":
            guard let value = body["value"] as? String, let preserver else { return }
            let merged = preserver.merge(current: value)
            guard merged != text else { return }
            text = merged
            onTextChange?(merged)
        case "openLink":
            guard let raw = body["url"] as? String, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            openExternally(url)
        case "latency":
            if let ms = body["ms"] as? Double {
                latencies.append(ms)
                processing.append(ms - ((body["queued"] as? Double) ?? 0))
                log.info("input latency \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            }
        case "blocked":
            let url = body["url"] as? String ?? "?"
            requestLog.append("blocked \(url)")
            log.error("blocked external request \(url, privacy: .public)")
        case "jsError":
            log.error("js error: \(body["message"] as? String ?? "", privacy: .public)")
        default:
            break
        }
    }

    /// Keyboard focus to the editor once it is ready. On a fresh launch the web view may not be in its
    /// window yet when the page reports ready, so retry for a few seconds.
    private func focusWhenInWindow(attempt: Int = 0) {
        if let window = webView.window {
            if window.firstResponder !== webView { window.makeFirstResponder(webView) }
            return
        }
        guard attempt < 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.focusWhenInWindow(attempt: attempt + 1) }
        }
    }

    // MARK: Navigation: the page never navigates anywhere

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        if action.targetFrame?.isMainFrame == true, action.navigationType == .other || action.navigationType == .reload,
           url?.scheme == SchemeHandler.scheme, url?.host() == "app", url?.path == "/web/index.html" {
            return .allow
        }
        requestLog.append("navigation refused \(url?.absoluteString ?? "?")")
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), let url,
           ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            openExternally(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        requestLog.append("new window refused \(action.request.url?.absoluteString ?? "?")")
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        preserver = nil
        webView.load(URLRequest(url: URL(string: "mdedit://app/web/index.html")!))
    }
}

/// Avoids the WKUserContentController -> handler retain cycle.
@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}
