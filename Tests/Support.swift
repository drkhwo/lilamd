import AppKit
import XCTest
@testable import MDEditor

enum Samples {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "samples")
    static func url(_ name: String) -> URL { dir.appending(path: name) }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func text(_ name: String) throws -> String { try MarkdownDocument(data: data(name)).text }
}

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 10, _ what: String = "condition", _ cond: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await cond() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw TimeoutError(description: "timed out waiting for \(what)")
}

/// A real window with a real WKWebView running the bundled Vditor.
@MainActor
final class EditorHarness {
    let window: NSWindow
    let controller: EditorController
    var changes: [String] = []
    var opened: [URL] = []

    init(text: String, mode: EditorMode = .visual, directory: URL? = Samples.dir) async throws {
        controller = EditorController(text: text, mode: mode, documentDirectory: directory)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.webView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        controller.onTextChange = { [unowned self] in self.changes.append($0) }
        controller.openExternally = { [unowned self] in self.opened.append($0) }
        try await waitUntil(20, "editor ready") { self.controller.isReady }
    }

    func close() { window.close() }

    @discardableResult
    func js(_ code: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await controller.evaluate(code, arguments: args)
    }

    func focus() async throws {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.webView)
        try await js("mdeditor.instance.focus()")
    }

    /// Selects the first occurrence of `word` inside the editor's text nodes.
    func select(_ word: String, collapseToEnd: Bool = false) async throws {
        let ok = try await js("""
        const root = mdeditor.root();
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const n = walker.currentNode; const i = n.textContent.indexOf(word);
          if (i >= 0) {
            const r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + word.length);
            if (collapseToEnd) r.collapse(false);
            const s = getSelection(); s.removeAllRanges(); s.addRange(r); return true;
          }
        }
        return false;
        """, ["word": word, "collapseToEnd": collapseToEnd]) as? Bool
        XCTAssertEqual(ok, true, "word \(word) not found in editor")
    }

    /// Types through the browser's editing pipeline (fires real `input` events).
    func insertText(_ s: String) async throws {
        try await js("document.execCommand('insertText', false, s)", ["s": s])
    }

    /// Sends a native key event through NSApp, the same path as the keyboard (menu key equivalents included).
    func key(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) async throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: keyCode)!
            NSApp.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(80))
    }

    func waitForText(_ timeout: TimeInterval = 5, line: Int = #line, _ cond: @escaping (String) -> Bool) async throws {
        try await waitUntil(timeout, "document text (line \(line)); text now: \(controller.text.suffix(80))") { cond(self.controller.text) }
    }
}

/// Lines of `a` and `b` that differ (by index, after aligning equal prefix/suffix).
func changedLineRange(_ a: String, _ b: String) -> (old: [Substring], new: [Substring]) {
    let x = a.split(separator: "\n", omittingEmptySubsequences: false)
    let y = b.split(separator: "\n", omittingEmptySubsequences: false)
    var p = 0
    while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
    var s = 0
    while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
    return (Array(x[p..<(x.count - s)]), Array(y[p..<(y.count - s)]))
}
