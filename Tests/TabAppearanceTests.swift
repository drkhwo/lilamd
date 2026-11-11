import AppKit
import SwiftUI
import WebKit
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
        for (name, page) in [(NSAppearance.Name.aqua, [255, 255, 255]), (.darkAqua, [0x24, 0x29, 0x2e])] {
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

    struct LivePage {
        let pixel: [Int]
        let report: String
    }

    /// What the editor page really paints: the bundled Vditor in a real WKWebView (background window), rendered with
    /// `takeSnapshot`, sampled in an empty area below the text. Also records the computed backgrounds of the layers.
    static func livePage(dark: Bool) async throws -> LivePage {
        let h = try await EditorHarness(text: "# Page\n\nShort paragraph.\n")
        defer { h.close() }
        try await h.js("mdeditor.setTheme(dark)", ["dark": dark])
        try await waitUntil(5, "theme applied") {
            try await h.js("return document.body.classList.contains('dark') === dark && !!document.querySelector('.vditor')"
                           + " && document.querySelector('.vditor').classList.contains('vditor--dark') === dark", ["dark": dark]) as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(800))
        let computed = try await h.js("""
        const out = [];
        for (const sel of ['html', 'body', '#editor', '.vditor', '.vditor-content', '.vditor-ir', '.vditor-ir pre.vditor-reset',
                           '.vditor-sv', '.vditor-wysiwyg']) {
          const el = document.querySelector(sel);
          if (!el) { out.push(sel + ': (none)'); continue; }
          const cs = getComputedStyle(el); const r = el.getBoundingClientRect();
          out.push(sel + ': background-color=' + cs.backgroundColor + ' display=' + cs.display
                   + ' rect=' + [r.x, r.y, r.width, r.height].map(Math.round).join(','));
        }
        const r = document.querySelector('.vditor-ir pre.vditor-reset').getBoundingClientRect();
        out.push('elementFromPoint(sample)=' + (document.elementFromPoint(r.x + r.width - 30, r.y + r.height - 30) || {}).className);
        return out.join(' | ');
        """) as? String ?? "(no result)"
        let image = try await h.controller.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let scale = Double(rep.pixelsWide) / image.size.width
        func at(_ x: Double, _ y: Double) -> [Int] { srgbPixel(rep, Int(x * scale), Int(y * scale)) }
        // Empty page area: right half, below the two lines of text; the window is 900 x 700.
        let points: [(Double, Double)] = [(700, 400), (450, 600), (800, 650), (600, 300)]
        let samples = points.map { at($0.0, $0.1) }
        let label = dark ? "dark" : "light"
        if let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: tabEvidence, withIntermediateDirectories: true)
            try png.write(to: tabEvidence.appending(path: "page-\(label).png"))
        }
        let report = """
        [\(label)] snapshot \(rep.pixelsWide)x\(rep.pixelsHigh) (scale \(scale)) colorSpace=\(rep.colorSpace.localizedName ?? "?") raw=\(rep.colorAt(x: Int(700 * scale), y: Int(400 * scale)).map { "\($0)" } ?? "?")
        \(computed)
        pixels (sRGB) at \(points.map { "(\(Int($0.0)),\(Int($0.1)))" }.joined(separator: " ")): \(samples)
        """
        XCTAssertEqual(Set(samples).count, 1, "\(label): the empty page area is one color: \(samples)")
        return LivePage(pixel: samples[0], report: report)
    }

    private static let tabEvidence = URL(fileURLWithPath: "/Users/stanislav/dev/QA/2026-11-11-lilamd-1.0/TAB")
    private static var liveCache: [Bool: LivePage] = [:]

    static func cachedLivePage(dark: Bool) async throws -> LivePage {
        if let p = liveCache[dark] { return p }
        let p = try await livePage(dark: dark)
        liveCache[dark] = p
        return p
    }

    /// The page color the tab uses equals what the real web view paints (±3 per channel). Writes `E/TAB/page-colour.txt`.
    func testPaletteMatchesLivePage() async throws {
        var text = "Measured \(Date()) in a background XCTest (real WKWebView, takeSnapshot, window off-screen).\n"
            + "Pixels: the snapshot bitmap is sRGB; raw components are read (no calibrated-RGB conversion, which shifts dark values).\n\n"
        for dark in [false, true] {
            let live = try await Self.cachedLivePage(dark: dark)
            let palette = srgb(EditorPalette.pageBackground, dark ? .darkAqua : .aqua)!
            let strip = srgb(EditorPalette.stripBackground, dark ? .darkAqua : .aqua)!
            text += live.report + "\nEditorPalette.pageBackground = \(palette)\nEditorPalette.stripBackground = \(strip)\n\n"
            for (a, b) in zip(palette, live.pixel) {
                XCTAssertLessThanOrEqual(abs(a - b), 3, "\(dark ? "dark" : "light"): palette \(palette) vs live page \(live.pixel)")
            }
        }
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try text.write(to: evidence.appending(path: "page-colour.txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    /// TAB-2. Tabs are 90 pt wide at least, so with 3 tabs the centers are about 45, 136 and 227.
    func testRenderedStripFourStates() async throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        var values = "TAB-2 samples (sRGB): active tab body, live page, neighbour tab, stripe, neighbour top\n"
        defer { try? values.write(to: evidence.appending(path: "render-values.txt"), atomically: true, encoding: .utf8) }
        for (dark, key) in [(false, true), (false, false), (true, true), (true, false)] {
            let label = "\(dark ? "dark" : "light")-\(key ? "key" : "nonkey")"
            let (window, hosting) = host(dark: dark, key: key)
            defer { window.close() }
            let rep = try snapshot(hosting)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: evidence.appending(path: "render-\(label).png"))
            }
            let scale = Double(rep.pixelsWide) / hosting.bounds.width
            // The page the real web view paints (Vditor in WKWebView, `takeSnapshot`), not the palette constant.
            let page = try await Self.cachedLivePage(dark: dark).pixel
            // Away from the label text: the right padding of the tab. Tabs are about 102 pt wide here.
            let active = pixel(rep, 195, 14, scale: scale)
            let neighbour = pixel(rep, 92, 14, scale: scale)
            for (a, p) in zip(active, page) {
                XCTAssertLessThanOrEqual(abs(a - p), 3, "\(label): active center \(active) vs live page \(page)")
            }
            XCTAssertGreaterThanOrEqual(diff(active, neighbour), 12, "\(label): neighbour \(neighbour) vs active \(active)")
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
