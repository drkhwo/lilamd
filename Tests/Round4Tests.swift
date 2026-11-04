import AppKit
import XCTest
@testable import MDEditor

@MainActor
final class Round4Tests: XCTestCase {
    var h: EditorHarness?
    private var originalZoom: Double?

    override func setUp() async throws {
        try await super.setUp()
        originalZoom = UserDefaults.standard.object(forKey: ZoomPreference.key) == nil
            ? nil : UserDefaults.standard.double(forKey: ZoomPreference.key)
    }

    override func tearDown() async throws {
        h?.close()
        h = nil
        if let originalZoom { UserDefaults.standard.set(originalZoom, forKey: ZoomPreference.key) }
        else { UserDefaults.standard.removeObject(forKey: ZoomPreference.key) }
        try await super.tearDown()
    }

    /// Stores the zoom and waits until the View > Zoom checkmark follows it. The scene's menu closures capture SwiftUI state
    /// that updates asynchronously, so a key sent too early would act on the previous value. SwiftUI refreshes the items'
    /// enabled state in `menuNeedsUpdate`, which AppKit calls when the user opens the menu, so it is called here once more.
    private func setStoredZoom(_ value: Double) async throws {
        UserDefaults.standard.set(value, forKey: ZoomPreference.key)
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        let steps = try XCTUnwrap(view.items.first { $0.title == "Zoom" }?.submenu)
        let title = ZoomPreference.label(value)
        for _ in 0..<50 where steps.items.first(where: { $0.title == title })?.state != .on {
            try await Task.sleep(for: .milliseconds(100))
            view.delegate?.menuNeedsUpdate?(view)
            steps.delegate?.menuNeedsUpdate?(steps)
            view.update()
        }
        view.delegate?.menuNeedsUpdate?(view)
        view.update()
        try await Task.sleep(for: .milliseconds(300))
    }

    func testZoomLadder() throws {
        XCTAssertEqual(ZoomPreference.steps, [0.8, 0.9, 1.0, 1.1, 1.2, 1.5])
        XCTAssertEqual(ZoomPreference.defaultValue, 1.0)
        XCTAssertEqual(ZoomPreference.snap(1.05), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ZoomPreference.next(after: 1.0), 1.1)
        XCTAssertNil(ZoomPreference.next(after: 1.5))
        XCTAssertEqual(ZoomPreference.previous(before: 1.0), 0.9)
        XCTAssertNil(ZoomPreference.previous(before: 0.8))
        XCTAssertEqual(ZoomPreference.next(after: 1.05), 1.1)
        // Z-2: an off-ladder value uses the nearest step above for next and the nearest step below for previous.
        // Old/snap-based behaviour: previous(1.05) snaps to 1.0 first and returns 0.9, so this fails.
        XCTAssertEqual(ZoomPreference.previous(before: 1.05), 1.0)
        XCTAssertEqual(ZoomPreference.next(after: 0.95), 1.0)
        XCTAssertEqual(ZoomPreference.previous(before: 0.95), 0.9)
        XCTAssertEqual(ZoomPreference.next(after: 1.45), 1.5)

        let suite = "mdeditor.zoom.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ZoomPreference.load(from: defaults), 1.0)
        ZoomPreference.save(1.05, to: defaults)
        XCTAssertEqual(ZoomPreference.load(from: try XCTUnwrap(UserDefaults(suiteName: suite))), 1.0)
    }

    func testSetZoomScalesPage() async throws {
        h = try await EditorHarness(text: "Zoom text")
        h!.controller.setZoom(1.5)
        XCTAssertEqual(h!.controller.webView.pageZoom, 1.5)
        let width = try await h!.js("return document.documentElement.clientWidth") as! Double
        XCTAssertEqual(width, 900.0 / 1.5, accuracy: 2)
        h!.controller.setZoom(0.8)
        XCTAssertEqual(h!.controller.webView.pageZoom, 0.8)
    }

    func testZoomSurvivesModeSwitch() async throws {
        h = try await EditorHarness(text: "Zoom text")
        h!.controller.setZoom(1.2)
        var readyCount = 0
        h!.controller.onReady = { readyCount += 1 }
        h!.controller.setMode(.source)
        try await waitUntil(10, "source mode ready") { readyCount > 0 }
        XCTAssertEqual(h!.controller.webView.pageZoom, 1.2)
    }

    func testZoomMenuItems() async throws {
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        let zoomIn = try XCTUnwrap(view.items.first { $0.title == "Zoom In" })
        let zoomOut = try XCTUnwrap(view.items.first { $0.title == "Zoom Out" })
        let actual = try XCTUnwrap(view.items.first { $0.title == "Actual Size" })
        XCTAssertEqual(zoomIn.keyEquivalent, "=")
        XCTAssertEqual(zoomIn.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(zoomOut.keyEquivalent, "-")
        XCTAssertEqual(actual.keyEquivalent, "0")
        let modeTitles = view.items.map(\.title)
        XCTAssertLessThan(modeTitles.firstIndex(of: "Visual")!, modeTitles.firstIndex(of: "Zoom In")!)
        XCTAssertLessThan(modeTitles.firstIndex(of: "Source")!, modeTitles.firstIndex(of: "Zoom In")!)
        let steps = try XCTUnwrap(view.items.first { $0.title == "Zoom" }?.submenu)
        XCTAssertEqual(steps.items.count, 6)
        try await setStoredZoom(1.0)
        XCTAssertEqual(steps.items.first { $0.title == "100 %" }?.state, .on)
        XCTAssertEqual(steps.items.first { $0.title == "110 %" }?.state, .off)
        // SwiftUI may rebuild the menu items, so they are looked up again after each change.
        func current(_ title: String) -> NSMenuItem? {
            NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.first { $0.title == title }
        }
        try await setStoredZoom(1.5)
        XCTAssertEqual(current("Zoom In")?.isEnabled, false, "Zoom In must be disabled at 150 %")
        try await setStoredZoom(0.8)
        XCTAssertEqual(current("Zoom Out")?.isEnabled, false, "Zoom Out must be disabled at 80 %")
        // NSApp's test harness does not host the SwiftUI scene command action target; item state is observable,
        // but invoking a nested Toggle here cannot reliably update the scene's @AppStorage binding.
    }

    func testMenuDoesNotTakeOptionCmdEquals() async throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func event(_ chars: String, ignoring: String, flags: NSEvent.ModifierFlags, keyCode: UInt16 = 24) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false,
                             keyCode: keyCode)!
        }
        // Shift+Cmd+= and Shift+Cmd+- as the US keyboard reports them ("+" / "_"; Shift changes charactersIgnoringModifiers).
        // A made-up event with "=" / "-" and Shift matches the Cmd+= / Cmd+- items: AppKit ignores Shift for such characters.
        XCTAssertFalse(menu.performKeyEquivalent(with: event("+", ignoring: "+", flags: [.command, .shift])))
        XCTAssertFalse(menu.performKeyEquivalent(with: event("_", ignoring: "_", flags: [.command, .shift], keyCode: 27)))
        XCTAssertFalse(menu.performKeyEquivalent(with: event("≠", ignoring: "=", flags: [.command, .option])))
        let old = UserDefaults.standard.object(forKey: ZoomPreference.key)
        try await setStoredZoom(1.0)
        XCTAssertTrue(menu.performKeyEquivalent(with: event("=", ignoring: "=", flags: .command)))
        // Z-11 probe: the menu action itself must change the stored zoom (separates menu wiring from key routing).
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 1.1, "menu action did not run")
        if let old { UserDefaults.standard.set(old, forKey: ZoomPreference.key) }
        else { UserDefaults.standard.removeObject(forKey: ZoomPreference.key) }
    }

    func testCmdEqualsZoomsAndDoesNotAddRow() async throws {
        let original = "| A | B |\n|---|---|\n| alpha | beta |\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("alpha", collapseToEnd: true)
        try await setStoredZoom(1.0)
        try await h!.key("=", keyCode: 24, flags: .command)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 1.1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(h!.controller.text, original)
        XCTAssertTrue(h!.changes.isEmpty)
    }

    func testCmdMinusInHeadingZoomsOnly() async throws {
        let original = "## Two\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("Two", collapseToEnd: true)
        try await setStoredZoom(1.0)
        try await h!.key("-", keyCode: 27, flags: .command)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 0.9)
        XCTAssertEqual(h!.controller.text, original)
    }

    func testCmdEqualsAtMaxZoomDoesNothing() async throws {
        let original = "| A | B |\n|---|---|\n| alpha | beta |\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("alpha", collapseToEnd: true)
        try await setStoredZoom(1.5)
        try await h!.key("=", keyCode: 24, flags: .command)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 1.5)
        XCTAssertEqual(h!.controller.text, original)
    }

    func testCmdMinusAtMinZoomDoesNothing() async throws {
        let original = "## Two\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("Two", collapseToEnd: true)
        try await setStoredZoom(0.8)
        try await h!.key("-", keyCode: 27, flags: .command)
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 0.8)
        XCTAssertEqual(h!.controller.text, original)
    }

    func testActualSizeShortcutResetsZoom() async throws {
        h = try await EditorHarness(text: "Reset zoom")
        try await setStoredZoom(1.5)
        try await h!.key("0", keyCode: 29, flags: .command)
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 1.0)
    }

    func testZoomPreferenceIsSharedByControllers() async throws {
        h = try await EditorHarness(text: "First")
        let second = try await EditorHarness(text: "Second")
        defer { second.close() }
        UserDefaults.standard.set(1.2, forKey: ZoomPreference.key)
        h!.controller.setZoom(ZoomPreference.snap(UserDefaults.standard.double(forKey: ZoomPreference.key)))
        second.controller.setZoom(ZoomPreference.snap(UserDefaults.standard.double(forKey: ZoomPreference.key)))
        XCTAssertEqual(h!.controller.webView.pageZoom, 1.2)
        XCTAssertEqual(second.controller.webView.pageZoom, 1.2)
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 1.2)
    }

    func testOptCmdMinusDeletesRow() async throws {
        let original = "| A | B |\n|---|---|\n| alpha | beta |\n| gamma | delta |\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("gamma", collapseToEnd: true)
        try await h!.key("–", ignoringModifiers: "-", keyCode: 27, flags: [.command, .option])
        try await h!.waitForText { !$0.contains("gamma") }
        XCTAssertFalse(h!.controller.text.contains("gamma"))
    }

    func testOptCmdEqualsRaisesHeading() async throws {
        let original = "## Two\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("Two", collapseToEnd: true)
        try await h!.key("≠", ignoringModifiers: "=", keyCode: 24, flags: [.command, .option])
        try await h!.waitForText { $0 == "# Two\n" }
        XCTAssertEqual(changedLineRange(original, h!.controller.text).new, ["# Two"])
    }

    func testOptCmdMinusLowersHeadingOneLine() async throws {
        let original = "## Two\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("Two", collapseToEnd: true)
        try await h!.key("–", ignoringModifiers: "-", keyCode: 27, flags: [.command, .option])
        try await h!.waitForText { $0 == "### Two\n" }
        XCTAssertEqual(changedLineRange(original, h!.controller.text).new, ["### Two"])
    }

    /// Z-13: Shift+Cmd+= adds a column as before and leaves zoom alone. Fails if the menu takes the key (zoom changes)
    /// or if the table source is rewritten outside the table.
    func testShiftCmdEqualsAddsColumnOnly() async throws {
        let original = "Intro line\n\n| A | B |\n|---|---|\n| alpha | beta |\n\nOutro line\n"
        h = try await EditorHarness(text: original)
        let before = try await h!.js("return mdeditor.root().querySelector('table').rows[0].cells.length") as! Int
        try await h!.focus(); try await h!.select("alpha", collapseToEnd: true)
        try await setStoredZoom(1.0)
        try await h!.key("+", ignoringModifiers: "+", keyCode: 24, flags: [.command, .shift])  // as from the US keyboard
        try await Task.sleep(for: .milliseconds(600))
        let after = try await h!.js("return mdeditor.root().querySelector('table').rows[0].cells.length") as! Int
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 1.0)
        XCTAssertEqual(after, before + 1, "Shift+Cmd+= must add a column")
        let text = h!.controller.text
        XCTAssertTrue(text.hasPrefix("Intro line\n\n"))
        XCTAssertTrue(text.hasSuffix("\n\nOutro line\n"))
    }

    func testShiftCmdMinusDeletesColumnOnly() async throws {
        let original = "| A | B | C |\n|---|---|---|\n| alpha | beta | gamma |\n"
        h = try await EditorHarness(text: original)
        try await h!.focus(); try await h!.select("beta", collapseToEnd: true)
        try await setStoredZoom(1.0)
        let before = try await h!.js("return mdeditor.root().querySelector('table').rows[0].cells.length") as! Int
        try await h!.key("_", ignoringModifiers: "_", keyCode: 27, flags: [.command, .shift])  // as from the US keyboard
        try await Task.sleep(for: .milliseconds(600))
        let after = try await h!.js("return mdeditor.root().querySelector('table').rows[0].cells.length") as! Int
        XCTAssertEqual(UserDefaults.standard.double(forKey: ZoomPreference.key), 1.0)
        XCTAssertEqual(after, before - 1, "Shift+Cmd+- must delete a column")
    }

    /// Z-9: a newly created editor applies the persisted preference through the same path as EditorView.
    func testZoomPersistsInDefaults() async throws {
        UserDefaults.standard.set(1.2, forKey: ZoomPreference.key)
        h = try await EditorHarness(text: "Persisted zoom")
        h!.controller.setZoom(ZoomPreference.load())
        XCTAssertEqual(h!.controller.webView.pageZoom, 1.2)
        XCTAssertEqual(ZoomPreference.key, "editorZoom")
    }

    /// Z-19: table cells still wrap at 150 %. Fails if zoom breaks the wrapping CSS (cells stay one line).
    func testZoomedTableStillWraps() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        h!.controller.setZoom(1.5)
        try await Task.sleep(for: .milliseconds(400))
        let m = try await h!.js("const t=document.querySelector('.vditor-ir table'); return {ws:getComputedStyle(t.rows[1].cells[1]).whiteSpace, sw:t.scrollWidth, cw:t.clientWidth, head:t.rows[0].cells[1].getBoundingClientRect().height, body:t.rows[1].cells[1].getBoundingClientRect().height}") as! [String: Any]
        XCTAssertEqual(m["ws"] as? String, "normal")
        XCTAssertLessThanOrEqual(m["sw"] as! Double, m["cw"] as! Double)
        XCTAssertGreaterThan(m["body"] as! Double, (m["head"] as! Double) * 3)
    }

    func testReadyReappliesZoom() async throws {
        h = try await EditorHarness(text: "Ready zoom")
        h!.controller.setZoom(1.2)
        h!.controller.webView.pageZoom = 1.0
        var readyCount = 0
        h!.controller.onReady = { readyCount += 1 }
        h!.controller.setMode(.source)
        try await waitUntil(10, "source ready") { readyCount > 0 }
        XCTAssertEqual(h!.controller.webView.pageZoom, 1.2)
    }

    func testT1_visualTableCellsWrap() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let styles = try await h!.js("""
        const td = document.querySelector('.vditor-ir table td');
        const th = document.querySelector('.vditor-ir table th');
        const pick = e => { const s = getComputedStyle(e); return { whiteSpace: s.whiteSpace, overflowWrap: s.overflowWrap, minWidth: s.minWidth, maxWidth: s.maxWidth, boxSizing: s.boxSizing }; };
        return { td: pick(td), th: pick(th), em: parseFloat(getComputedStyle(td).fontSize) * 4 };
        """) as! [String: Any]
        for key in ["td", "th"] {
            let cell = styles[key] as! [String: String]
            XCTAssertEqual(cell["whiteSpace"], "normal")
            XCTAssertEqual(cell["overflowWrap"], "break-word")
            XCTAssertEqual(cell["boxSizing"], "border-box")
            XCTAssertEqual(Double(cell["maxWidth"]!.replacingOccurrences(of: "px", with: ""))!, (styles["em"] as! Double) * 6, accuracy: 1, "max-width must be 24em")
            XCTAssertEqual(Double(cell["minWidth"]!.replacingOccurrences(of: "px", with: ""))!, (styles["em"] as! Double), accuracy: 1)
        }
    }

    /// T-1 / round-1 blocker: `overflow-wrap: anywhere` shrinks min-content, so ordinary words are torn when columns are squeezed.
    /// Eight 20-letter words do not fit in 900 pt. With `break-word` the table scrolls and every word stays on one line.
    func testT1_ordinaryWordsAreNotBrokenInSqueezedColumns() async throws {
        let cells = Array(repeating: "Internationalization", count: 8)
        let text = "| " + cells.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 8) + "\n| " + cells.joined(separator: " | ") + " |\n"
        h = try await EditorHarness(text: text)
        let r = try await h!.js("""
        const t=document.querySelector('.vditor-ir table');
        const lines = c => { const g=document.createRange(); g.selectNodeContents(c);
          return new Set(Array.from(g.getClientRects()).map(x=>Math.round(x.top))).size; };
        return {lines:Array.from(t.rows).flatMap(r=>Array.from(r.cells).map(lines))};
        """) as! [String: [Double]]
        XCTAssertEqual(r["lines"]!.count, 16)
        XCTAssertTrue(r["lines"]!.allSatisfy { $0 == 1 }, "ordinary word was broken: \(r)")
    }

    func testT2_longParagraphFitsEditor() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let sizes = try await h!.js("const t = document.querySelector('.vditor-ir table'); const r = document.querySelector('.vditor-ir'); return {sw:t.scrollWidth, cw:t.clientWidth, rw:r.clientWidth}") as! [String: Double]
        XCTAssertLessThanOrEqual(sizes["sw"]!, sizes["cw"]!)
        XCTAssertLessThanOrEqual(sizes["sw"]!, sizes["rw"]!)
    }

    /// Cells of one row stretch to the same height, so compare the body row with the one-line header row.
    /// Old behaviour (`white-space: nowrap`): the body row is one line tall, same as the header.
    func testT3_longCellIsTallerThanHeaderRow() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let m = try await h!.js("const t=document.querySelector('.vditor-ir table'); return {head:t.rows[0].cells[1].getBoundingClientRect().height, body:t.rows[1].cells[1].getBoundingClientRect().height}") as! [String: Double]
        XCTAssertGreaterThan(m["body"]!, m["head"]! * 3, "400-char paragraph must wrap to several lines: \(m)")
    }

    func testT4_urlBreaksInsideCell() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let r = try await h!.js("const t=document.querySelectorAll('.vditor-ir table')[1]; return {sw:t.scrollWidth,cw:t.clientWidth,head:t.rows[0].cells[1].getBoundingClientRect().height,cell:t.rows[1].cells[1].getBoundingClientRect().height}") as! [String: Double]
        XCTAssertLessThanOrEqual(r["sw"]!, r["cw"]!, "no sideways scroll for a 120-char URL: \(r)")
        XCTAssertGreaterThan(r["cell"]!, r["head"]! * 1.5, "URL must break into several lines: \(r)")
        let w = try await h!.js("const t=document.querySelectorAll('.vditor-ir table')[1]; const td=t.rows[1].cells[1]; return {w:td.getBoundingClientRect().width, em:parseFloat(getComputedStyle(td).fontSize)*24}") as! [String: Double]
        XCTAssertLessThanOrEqual(w["w"]!, w["em"]! + 1, "URL column is capped at 24em: \(w)")
    }

    /// Border-box keeps the 12-column table within the editor; a generated 24-column table exercises fallback scrolling.
    func testT5_wideTableRetainsFallbackScrolling() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let values = try await h!.js("""
        const t=document.querySelectorAll('.vditor-ir table')[2];
        if (t.rows[0].cells.length !== 12) throw new Error('not table (c)');
        const s=getComputedStyle(t);
        const em=parseFloat(getComputedStyle(t.rows[0].cells[0]).fontSize)*4;
        return {display:s.display,overflowX:s.overflowX,scrollWidth:t.scrollWidth,clientWidth:t.clientWidth,
          em,widths:Array.from(t.rows[0].cells).map(cell=>cell.getBoundingClientRect().width),
          boxSizing:getComputedStyle(t.rows[0].cells[0]).boxSizing,
          lastRight:t.rows[0].cells[t.rows[0].cells.length-1].getBoundingClientRect().right,
          tableRight:t.getBoundingClientRect().right,
          cellsSum:Array.from(t.rows[0].cells).reduce((a,c)=>a+c.getBoundingClientRect().width,0)};
        """) as! [String: Any]
        XCTAssertEqual(values["display"] as? String, "block")
        XCTAssertEqual(values["overflowX"] as? String, "auto")
        XCTAssertLessThanOrEqual(values["scrollWidth"] as! Double, (values["clientWidth"] as! Double) + 1)
        let minWidth = values["em"] as! Double
        for width in values["widths"] as! [Double] {
            XCTAssertGreaterThanOrEqual(width + 1, minWidth)
        }
        // With border-box a 4em column is 60 pt, so all 12 short columns fit.
        XCTAssertEqual(values["boxSizing"] as? String, "border-box")
        XCTAssertLessThanOrEqual(values["lastRight"] as! Double, (values["tableRight"] as! Double) + 1, "last column C12 is clipped: \(values)")
        XCTAssertLessThanOrEqual(values["cellsSum"] as! Double, (values["clientWidth"] as! Double) + 1, "12 columns must fit: \(values)")

        h!.close()
        let headers = (1...24).map { "C\($0)" }
        let separators = headers.map { String(repeating: "-", count: max(3, $0.count)) }
        let wideTable = ([headers, separators, headers].map {
            "| " + $0.joined(separator: " | ") + " |"
        }).joined(separator: "\n")
        h = try await EditorHarness(text: wideTable)
        let fallback = try await h!.js("""
        const t=document.querySelector('.vditor-ir table');
        const s=getComputedStyle(t);
        return {display:s.display,overflowX:s.overflowX,scrollWidth:t.scrollWidth,clientWidth:t.clientWidth};
        """) as! [String: Any]
        XCTAssertEqual(fallback["display"] as? String, "block")
        XCTAssertEqual(fallback["overflowX"] as? String, "auto")
        XCTAssertGreaterThan(fallback["scrollWidth"] as! Double, fallback["clientWidth"] as! Double)
    }

    /// T-11: `:---:` and `---:` alignment survives wrapping.
    func testT11_columnAlignmentSurvivesWrapping() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"))
        let a = try await h!.js("const t=document.querySelector('.vditor-ir table'); return {head:[0,1,2].map(i=>getComputedStyle(t.rows[0].cells[i]).textAlign), body:[0,1,2].map(i=>getComputedStyle(t.rows[1].cells[i]).textAlign)}") as! [String: [String]]
        // WebKit reports `-webkit-center` / `-webkit-right` for `align="center|right"`; default column is `start`.
        XCTAssertEqual(a["head"], ["-webkit-center", "center", "-webkit-right"])
        XCTAssertEqual(a["body"], ["-webkit-center", "start", "-webkit-right"])
    }

    func testT6_sourceModeRemainsMonospacedAndUnchanged() async throws {
        h = try await EditorHarness(text: try Samples.text("wide-table.md"), mode: .source)
        let values = try await h!.js("const s=document.querySelector('.vditor-sv'); const c=getComputedStyle(s); const td=s.querySelector('td'); return {font:c.fontFamily,hasCell:!!td, cellWrap:td ? getComputedStyle(td).whiteSpace : ''}") as! [String: Any]
        let font = values["font"] as! String
        XCTAssertTrue(font.lowercased().contains("mono") || font.contains("Menlo"))
        // `.vditor-sv` is itself a `.vditor-reset`, so the td/th rule is inert only because Source renders no table cells.
        XCTAssertEqual(values["hasCell"] as? Bool, false)
        XCTAssertNotEqual(values["cellWrap"] as? String, "normal")
    }

    func testT7_longCellEditChangesOnlyItsSourceRow() async throws {
        let original = try Samples.text("wide-table.md")
        h = try await EditorHarness(text: original)
        try await h!.focus()
        try await h!.select("approximately four hundred characters", collapseToEnd: true)
        try await h!.insertText(" exactly four hundred characters")
        try await h!.waitForText { $0.contains("exactly four hundred characters") }
        let diff = changedLineRange(original, h!.controller.text)
        XCTAssertEqual(diff.old.count, 1)
        XCTAssertEqual(diff.new.count, 1)
    }

    func testT8_loadingWideTablePreservesSource() async throws {
        let original = try Samples.text("wide-table.md")
        h = try await EditorHarness(text: original)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(h!.changes.isEmpty)
        XCTAssertEqual(h!.controller.text, original)
    }

    func testT9_longFirstCellKeepsCaretAtTableStart() async throws {
        let original = "| \(String(repeating: "long first cell text ", count: 20)) | Value |\n|---|---|\n| a | b |\n"
        h = try await EditorHarness(text: original)
        try await h!.focus()
        try await Task.sleep(for: .milliseconds(300))
        try await h!.key(String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), keyCode: 126, flags: [.command, .numericPad, .function])
        try await Task.sleep(for: .milliseconds(300))
        try await h!.key("7", keyCode: 26)
        try await h!.waitForText { $0 != original }
        try await Task.sleep(for: .milliseconds(500))
        let diff = changedLineRange(original, h!.controller.text)
        XCTAssertTrue(h!.controller.text.hasPrefix("| "), "text before the table: \(h!.controller.text.prefix(40).debugDescription)")
        XCTAssertEqual(diff.old.map(String.init), [original.components(separatedBy: "\n")[0]])
        XCTAssertEqual(diff.new.count, 1)
        XCTAssertTrue(diff.new.first?.components(separatedBy: "|").dropFirst().first?.contains("7") == true, "first cell: \(diff.new)")
        let above = try await h!.js("const t=mdeditor.root().querySelector('table'); return !!t.previousElementSibling") as? Bool
        XCTAssertEqual(above, false, "nothing is rendered above the table")
    }
}
