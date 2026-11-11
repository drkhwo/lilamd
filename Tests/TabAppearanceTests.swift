import AppKit
import SwiftUI
import XCTest
@testable import MDEditor

/// Active-tab highlight (1.0 plan, 1.1): the pure style, a strip rendered without the screen, AX traits and width.
/// The tab bar sits in a borderless window parked off-screen. The window is never made key and the app never activates.
@MainActor
final class TabAppearanceTests: XCTestCase {
    private var dir: URL!
    private var store: TabStore!
    private let evidence = URL(fileURLWithPath: "/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0/TAB")

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appending(path: "tabappearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false
        for name in ["alpha.md", "bravo.md", "charlie.md"] {
            let url = dir.appending(path: name)
            try Data("# \(name)\n".utf8).write(to: url)
            _ = try store.open(url)
        }
        store.activate(store.order[1])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    // MARK: TAB-1

    private func srgb(_ color: NSColor?, _ appearance: NSAppearance.Name) -> [Int]? {
        guard let color else { return nil }
        var out: [Int]?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            out = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        return out
    }

    func testAppearanceIsPureAndDiffersByState() {
        for (name, page) in [(NSAppearance.Name.aqua, [0xfa, 0xfb, 0xfc]), (.darkAqua, [0x2f, 0x36, 0x3d])] {
            for key in [true, false] {
                let active = TabAppearance(isActive: true, isKeyWindow: key)
                let inactive = TabAppearance(isActive: false, isKeyWindow: key)
                XCTAssertEqual(srgb(active.backgroundNSColor, name), page, "active background = page color, \(name.rawValue)")
                XCTAssertNil(inactive.backgroundNSColor)
                XCTAssertNil(inactive.stripeNSColor)
                XCTAssertEqual(active.weight, .semibold)
                XCTAssertEqual(inactive.weight, .regular)
            }
        }
        XCTAssertEqual(TabAppearance(isActive: true, isKeyWindow: true).stripeNSColor, NSColor.controlAccentColor)
        XCTAssertEqual(TabAppearance(isActive: true, isKeyWindow: false).stripeNSColor, NSColor.tertiaryLabelColor)
    }

    // MARK: Rendering

    private func host(dark: Bool, key: Bool) -> (NSWindow, NSHostingView<AnyView>) {
        let view = AnyView(TabBarView(store: store, openFiles: { _ in })
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, key ? .key : .inactive)
            .frame(width: 600, height: 28))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 28), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // sRGB backing store: the snapshot is sRGB on any screen, so no display profile enters the comparison.
        window.colorSpace = .sRGB
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)   // never makeKey, never activates
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func snapshot(_ hosting: NSView) throws -> NSBitmapImageRep {
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// `y` counts from the top of the view, like the bitmap rows.
    private func pixel(_ rep: NSBitmapImageRep, _ x: Double, _ y: Double, scale: Double) -> [Int] {
        Self.srgbPixel(rep, Int(x * scale), Int(y * scale))
    }

    /// sRGB 0–255 of one bitmap pixel. The bitmap is converted to sRGB first, then its raw components are read:
    /// `colorAt(...)` returns a calibrated-RGB color, and `usingColorSpace(.sRGB)` on it shifts dark values by up to 12.
    static func srgbPixel(_ rep: NSBitmapImageRep, _ px: Int, _ py: Int) -> [Int] {
        let srgb = rep.colorSpace == .sRGB ? rep : (rep.converting(to: .sRGB, renderingIntent: .default) ?? rep)
        guard let c = srgb.colorAt(x: px, y: py) else { return [0, 0, 0] }
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    private func diff(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.reduce(0, +) }

    // MARK: The live page

    /// The page background as CSS computes it (sRGB 0–255), in the state the page is in and with the editor focused.
    struct PageColour {
        let asIs: [Int]
        let focused: [Int]
        let report: String
    }

    private static let runLabel = TestBackground.isOn ? "bg" : "fg"

    /// Builds the page the way the app does: `MainWindowController` + `TabStore`, the tab's own `EditorController`,
    /// the theme from `NSApp.effectiveAppearance`, the mode from the stored preference. Then reads the computed
    /// background of the element painted at the centre of the editor (`elementFromPoint`, walking up to the first
    /// non-transparent background). No pixels: the result does not depend on the display or its colour profile.
    ///
    /// Vditor paints the page with a `:focus` rule (`--textarea-background-color`). WebKit matches `:focus` only in an
    /// active window, and the background run never activates the app, so `asIs` is the unfocused page there and the
    /// focused page in a foreground run. `focused` copies every `:focus` rule onto a class on the focused editor root,
    /// so both states are measured in both runs.
    static func pageColour(dark: Bool, mode: EditorMode) async throws -> PageColour {
        let savedAppearance = NSApp.appearance
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: EditorModePreference.key)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defaults.set(mode.rawValue, forKey: EditorModePreference.key)
        defer {
            NSApp.appearance = savedAppearance
            if let savedMode { defaults.set(savedMode, forKey: EditorModePreference.key) } else { defaults.removeObject(forKey: EditorModePreference.key) }
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "pagecolour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "page.md")
        try Data("# Page\n\nShort paragraph.\n".utf8).write(to: url)
        let store = TabStore(prompter: FakePrompter())
        store.recordsRecents = false
        let wc = MainWindowController(store: store)
        defer { wc.window?.close() }
        XCTAssertTrue(wc.open([url], present: { XCTFail("open failed: \($0.informativeText)") }))
        let doc = try XCTUnwrap(store.active)
        try await waitUntil(20, "editor ready") { doc.controller?.isReady == true }
        let controller = try XCTUnwrap(doc.controller)
        try await waitUntil(5, "theme applied") {
            try await controller.evaluate("const v = document.querySelector('.vditor');"
                + " return document.body.classList.contains('dark') === dark && !!v && v.classList.contains('vditor--dark') === dark",
                arguments: ["dark": dark]) as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(300))
        let result = try await controller.evaluate("""
        const x = Math.round(innerWidth / 2), y = Math.round(innerHeight / 2);
        function name(e) { return e.tagName.toLowerCase() + (typeof e.className === 'string' && e.className.trim() ? '.' + e.className.trim().split(/\\s+/).join('.') : ''); }
        function painted() {
          const hit = document.elementFromPoint(x, y);
          for (let e = hit; e; e = e.parentElement) {
            const css = getComputedStyle(e).backgroundColor;
            const n = (css.match(/[\\d.]+/g) || []).map(Number);
            if (n.length === 3 || (n.length === 4 && n[3] > 0)) {
              return { rgb: n.slice(0, 3), alpha: n.length === 4 ? n[3] : 1, css: css, el: name(e), hit: hit ? name(hit) : '(none)' };
            }
          }
          return { rgb: [], alpha: 0, css: 'transparent', el: '(none)', hit: hit ? name(hit) : '(none)' };
        }
        const asIs = painted();
        const root = mdeditor.root();
        const state = 'activeElement=' + (document.activeElement ? name(document.activeElement) : '(none)')
          + ' rootIsActive=' + (document.activeElement === root)
          + ' hasFocus=' + document.hasFocus() + ' root.matches(:focus)=' + (root ? root.matches(':focus') : false);
        const copies = [];
        for (const sheet of document.styleSheets) {
          let rules; try { rules = sheet.cssRules; } catch (e) { continue; }
          for (const r of rules) {
            if (r instanceof CSSStyleRule && /:focus(?![-\\w])/.test(r.selectorText)) {
              copies.push(r.selectorText.replace(/:focus(?![-\\w])/g, '.mdeditor-test-focus') + ' { ' + r.style.cssText + ' }');
            }
          }
        }
        const style = document.createElement('style');
        style.textContent = copies.join('\\n');
        document.head.appendChild(style);
        root.classList.add('mdeditor-test-focus');
        const focused = painted();
        root.classList.remove('mdeditor-test-focus');
        style.remove();
        return { asIs: asIs, focused: focused, state: state, point: x + ',' + y };
        """, arguments: [:]) as? [String: Any]
        for doc in store.tabs { _ = await store.close(doc.id) }
        let r = try XCTUnwrap(result)
        func rgb(_ key: String) throws -> ([Int], String) {
            let o = try XCTUnwrap(r[key] as? [String: Any], key)
            let c = (o["rgb"] as? [NSNumber] ?? []).map { Int(truncating: $0) }
            let alpha = (o["alpha"] as? NSNumber)?.doubleValue ?? 0
            XCTAssertEqual(c.count, 3, "\(key): no painted background at the centre: \(o)")
            XCTAssertEqual(alpha, 1, "\(key): the painted background is not opaque: \(o)")
            return (c, "\(o["el"] ?? "?") \(o["css"] ?? "?") (hit \(o["hit"] ?? "?"))")
        }
        let (asIs, asIsText) = try rgb("asIs")
        let (focused, focusedText) = try rgb("focused")
        let report = """
        [\(dark ? "dark" : "light"), \(mode.rawValue)] centre \(r["point"] ?? "?") \(r["state"] ?? "?")
          as is:   \(asIsText) -> \(asIs)
          focused: \(focusedText) -> \(focused)
        """
        return PageColour(asIs: asIs, focused: focused, report: report)
    }

    private static var pageCache: [String: PageColour] = [:]

    static func cachedPageColour(dark: Bool, mode: EditorMode = .visual) async throws -> PageColour {
        let key = "\(dark)-\(mode.rawValue)"
        if let p = pageCache[key] { return p }
        let p = try await pageColour(dark: dark, mode: mode)
        pageCache[key] = p
        return p
    }

    /// TAB-1. The active tab colour equals the page's computed background (±3 per channel), focused and not, light and
    /// dark, Visual and Source. The strip differs from both. Writes `E/TAB/page-css-bg.txt` (`-fg.txt` in a foreground run).
    func testPaletteMatchesLivePage() async throws {
        var text = "Measured \(Date()) (\(Self.runLabel) run): app window (MainWindowController), computed CSS background "
            + "of the element at the editor centre, sRGB 0–255.\n\n"
        for dark in [false, true] {
            let palette = srgb(EditorPalette.pageBackground, dark ? .darkAqua : .aqua)!
            let strip = srgb(EditorPalette.stripBackground, dark ? .darkAqua : .aqua)!
            text += "EditorPalette.pageBackground = \(palette), stripBackground = \(strip)\n"
            for mode in [EditorMode.visual, .source] {
                let page = try await Self.cachedPageColour(dark: dark, mode: mode)
                text += page.report + "\n"
                for (state, colour) in [("as is", page.asIs), ("focused", page.focused)] {
                    for (a, b) in zip(palette, colour) {
                        XCTAssertLessThanOrEqual(abs(a - b), 3, "\(dark ? "dark" : "light") \(mode.rawValue) \(state): tab \(palette) vs page \(colour)")
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(diff(strip, palette), 12, "strip \(strip) vs page/tab \(palette)")
            text += "\n"
        }
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try text.write(to: evidence.appending(path: "page-css-\(Self.runLabel).txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    /// TAB-2. Tabs are 90 pt wide at least, so with 3 tabs the centers are about 45, 136 and 227.
    /// The strip renders into an sRGB window (`host`), so its pixels are sRGB on any screen; the page colour is the
    /// computed CSS value (sRGB). Both sides are in one colour space, and no display profile enters the comparison.
    func testRenderedStripFourStates() async throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var values = "TAB-2 samples (sRGB, \(Self.runLabel) run): active tab body, page (computed CSS, focused), neighbour tab, stripe, neighbour top\n"
        defer { try? values.write(to: evidence.appending(path: "render-values-\(Self.runLabel).txt"), atomically: true, encoding: .utf8) }
        for (dark, key) in [(false, true), (false, false), (true, true), (true, false)] {
            let label = "\(dark ? "dark" : "light")-\(key ? "key" : "nonkey")"
            let (window, hosting) = host(dark: dark, key: key)
            defer { window.close() }
            let rep = try snapshot(hosting)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: evidence.appending(path: "render-\(label)-\(Self.runLabel).png"))
            }
            let scale = Double(rep.pixelsWide) / hosting.bounds.width
            let page = try await Self.cachedPageColour(dark: dark).focused
            // Away from the label text: the right padding of the tab. Tabs are about 102 pt wide here.
            let active = pixel(rep, 195, 14, scale: scale)
            let neighbour = pixel(rep, 92, 14, scale: scale)
            for (a, p) in zip(active, page) {
                XCTAssertLessThanOrEqual(abs(a - p), 3, "\(label): active center \(active) vs page \(page)")
            }
            XCTAssertGreaterThanOrEqual(diff(active, neighbour), 12, "\(label): neighbour \(neighbour) vs active \(active)")
            XCTAssertGreaterThanOrEqual(diff(page, neighbour), 12, "\(label): neighbour \(neighbour) vs page \(page)")
            // Stripe: top 2 pt, sampled at 1 pt, away from the label.
            let top = pixel(rep, 150, 0.5, scale: scale)
            let other = pixel(rep, 50, 0.5, scale: scale)
            values += "\(label): active=\(active) page=\(page) neighbour=\(neighbour) stripe=\(top) neighbourTop=\(other)\n"
            XCTAssertGreaterThanOrEqual(diff(top, active), 12, "\(label): stripe \(top) vs tab body \(active)")
            XCTAssertGreaterThanOrEqual(diff(top, other), 12, "\(label): stripe \(top) vs neighbour top \(other)")
            if key {
                let accent = srgb(.controlAccentColor, dark ? .darkAqua : .aqua)!
                XCTAssertLessThanOrEqual(diff(top, accent), 30, "\(label): stripe \(top) vs accent \(accent)")
            } else {
                // Gray: no color cast.
                XCTAssertLessThanOrEqual((top.max() ?? 0) - (top.min() ?? 0), 12, "\(label): stripe \(top) is not gray")
            }
        }
    }

    // MARK: AX and width

    /// TAB-3. SwiftUI builds its AX tree only for a live accessibility client, so the test checks the values the view
    /// applies (`TabAccessibility`). The real AX tree is in FOREGROUND.md step 10.
    func testAXIdentifiersAndSelectedTrait() {
        func state() -> [String] {
            store.tabs.filter { TabAccessibility.traits(isActive: $0.id == store.activeID).contains(.isSelected) }
                .map { TabAccessibility.identifier($0.displayName) }
        }
        XCTAssertEqual(store.tabs.map { TabAccessibility.identifier($0.displayName) },
                       ["tab:alpha.md", "tab:bravo.md", "tab:charlie.md"])
        XCTAssertEqual(state(), ["tab:bravo.md"])
        store.activate(store.order[2])
        XCTAssertEqual(state(), ["tab:charlie.md"])
    }

    /// TAB-6. The hidden semibold copy keeps the width when a tab becomes active.
    func testTabWidthDoesNotChangeOnActivate() throws {
        // Between the 90 and 200 pt limits, so the name decides the width.
        let long = dir.appending(path: "medium-name.md")
        try Data("x".utf8).write(to: long)
        let doc = try store.open(long, activate: false)
        func width(active: Bool) -> CGFloat {
            let view = TabItem(store: store, document: doc, isActive: active, isOnly: false, isLast: false).fixedSize()
            return NSHostingView(rootView: view).fittingSize.width
        }
        let inactive = width(active: false), active = width(active: true)
        XCTAssertTrue(inactive > 95 && inactive < 195, "name must decide the width, not the 90/200 limits: \(inactive)")
        XCTAssertEqual(inactive, active, accuracy: 1, "inactive \(inactive), active \(active)")
    }
}
