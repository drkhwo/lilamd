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
        for (name, page) in [(NSAppearance.Name.aqua, [255, 255, 255]), (.darkAqua, [0x1d, 0x21, 0x25])] {
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
        let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .black
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    private func diff(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.reduce(0, +) }

    private func referencePixel(dark: Bool) throws -> [Int] {
        let hosting = NSHostingView(rootView: Color(nsColor: EditorPalette.pageBackground).frame(width: 20, height: 20)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        defer { window.close() }
        let rep = try snapshot(hosting)
        return pixel(rep, 10, 10, scale: Double(rep.pixelsWide) / 20)
    }

    /// TAB-2. Tabs are 90 pt wide at least, so with 3 tabs the centers are about 45, 136 and 227.
    func testRenderedStripFourStates() throws {
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for (dark, key) in [(false, true), (false, false), (true, true), (true, false)] {
            let label = "\(dark ? "dark" : "light")-\(key ? "key" : "nonkey")"
            let (window, hosting) = host(dark: dark, key: key)
            defer { window.close() }
            let rep = try snapshot(hosting)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: evidence.appending(path: "render-\(label).png"))
            }
            let scale = Double(rep.pixelsWide) / hosting.bounds.width
            // The same pipeline draws the page color alone: the tab must match it (the pure value is TAB-1).
            let page = try referencePixel(dark: dark)
            // Away from the label text: the right padding of the tab. Tabs are about 102 pt wide here.
            let active = pixel(rep, 195, 14, scale: scale)
            let neighbour = pixel(rep, 92, 14, scale: scale)
            XCTAssertLessThanOrEqual(diff(active, page), 9, "\(label): active center \(active) vs page \(page)")
            XCTAssertGreaterThanOrEqual(diff(active, neighbour), 12, "\(label): neighbour \(neighbour) vs active \(active)")
            // Stripe: top 2 pt, sampled at 1 pt, away from the label.
            let top = pixel(rep, 150, 0.5, scale: scale)
            let other = pixel(rep, 50, 0.5, scale: scale)
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
