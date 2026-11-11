// Helper for the FOREGROUND steps 20 and 21. Compiled once per step: `swiftc -O scripts/fg/fgtool.swift -o <tmp>/fgtool`.
// It takes the screen (activation, CGEvent keys and mouse, input source): run only from the FOREGROUND.md batch.
// Every app-specific command takes the pid of the Debug app, never a name: the installed LilaMD may be running too.
//
//   activate <pid>                      bring the app to the front; exit 1 if it is not frontmost after 3 s
//   frontmost                           pid of the frontmost app
//   windows <pid>                       "<CGWindowID> <x> <y> <w> <h> <layer> <name>" for each on-screen window
//   frame <pid>                         "<x> <y> <w> <h>" of the app's AX main window (top-left origin)
//   tabs <pid>                          "tab:<name> selected=<bool> <x> <y> <w> <h>" per tab, in screen order
//   hold-focus <seconds>                a window-less accessory process takes the focus and keeps it (the app under test becomes
//                                       inactive without Stage Manager moving its window into the side strip)
//   dump <pid>                          the whole AX tree of every window: role, subrole, identifier, title, selected, frame
//   edited <pid>                        true|false|unknown: the "edited" mark of the main window (close button AXEdited)
//   hit <x> <y>                         "<pid> <role>" of the AX element at a screen point
//   texts <pid>                         "<window subrole>: <text>" for the static texts of every window (alerts, panels)
//   menu-items <pid> <top title>        AX titles of a top-level menu's items ("-" for a separator)
//   menu <pid> <title> <title> …        press a menu item by path through AX (e.g. File "Close Tab")
//   press <pid> <button title>          press a button of the frontmost window or sheet through AX
//   click <x> <y> [count]               left click (count 2 = double click) at screen point
//   drag <x1> <y1> <x2> <y2>            left-button drag in 20 steps
//   type <text>                         Unicode key events (independent of the keyboard layout)
//   key <keycode> [cmd] [shift] [ctrl] [opt]
//   source-get                          id of the current keyboard input source
//   source-set <id>                     select an enabled input source
//   default-browser                     bundle id of the https handler
import AppKit
import ApplicationServices
import Carbon

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("no command") }

func pidArg(_ i: Int = 1) -> pid_t { pid_t(args.count > i ? Int32(args[i]) ?? 0 : 0) }
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func point(_ e: AXUIElement) -> CGPoint {
    var p = CGPoint.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    return p
}
func size(_ e: AXUIElement) -> CGSize {
    var s = CGSize.zero
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return s
}
func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Void) {
    visit(e)
    guard depth < 40 else { return }
    for c in children(e) { walk(c, depth: depth + 1, visit) }
}
func mainWindow(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    let windows = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    // The tab window is the largest one (About and alerts are small).
    return windows.max { size($0).width * size($0).height < size($1).width * size($1).height }
}
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(15_000) }
func mouse(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks)
    post(e)
}
func num(_ i: Int) -> CGFloat {
    guard let d = Double(args.count > i ? args[i] : "") else { fail("number expected at \(i)") }
    return CGFloat(d)
}

switch cmd {
case "activate":
    guard let app = NSRunningApplication(processIdentifier: pidArg()) else { fail("no such pid") }
    app.activate()
    for _ in 0..<30 {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { exit(0) }
        usleep(100_000)
    }
    fail("not frontmost")
case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pidArg() {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let f = { (k: String) in (b[k] as? Double).map { Int($0) } ?? 0 }
        print(w[kCGWindowNumber as String] as? Int ?? 0, f("X"), f("Y"), f("Width"), f("Height"),
              w[kCGWindowLayer as String] as? Int ?? 0, w[kCGWindowName as String] as? String ?? "")
    }
case "frame":
    guard let w = mainWindow(pidArg()) else { fail("no window") }
    let p = point(w), s = size(w)
    print(Int(p.x), Int(p.y), Int(s.width), Int(s.height))
case "tabs":
    guard let w = mainWindow(pidArg()) else { fail("no window") }
    var rows: [(CGFloat, String)] = []
    walk(w) { e in
        guard let id = attr(e, "AXIdentifier") as? String, id.hasPrefix("tab:") else { return }
        let sel = (attr(e, kAXSelectedAttribute) as? Bool) ?? false
        let p = point(e), s = size(e)
        rows.append((p.x, "\(id) selected=\(sel) \(Int(p.x)) \(Int(p.y)) \(Int(s.width)) \(Int(s.height))"))
    }
    for r in rows.sorted(by: { $0.0 < $1.0 }) { print(r.1) }
case "hold-focus":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: Double(args.count > 1 ? args[1] : "30") ?? 30))
case "dump":
    let app = AXUIElementCreateApplication(pidArg())
    func dump(_ e: AXUIElement, _ depth: Int) {
        guard depth < 40 else { return }
        let f = { (n: String) in (attr(e, n) as? String).map { $0.isEmpty ? "" : $0 } ?? "" }
        let p = point(e), s = size(e)
        let sel = (attr(e, kAXSelectedAttribute) as? Bool).map { " selected=\($0)" } ?? ""
        print(String(repeating: "  ", count: depth) + "\(f(kAXRoleAttribute)) sub=\(f(kAXSubroleAttribute)) id=\(f("AXIdentifier")) title=\(f(kAXTitleAttribute)) desc=\(f(kAXDescriptionAttribute))\(sel) [\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height))]")
        for c in children(e) { dump(c, depth + 1) }
    }
    for w in attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] { dump(w, 0) }
case "edited":
    guard let w = mainWindow(pidArg()) else { fail("no window") }
    let close = attr(w, kAXCloseButtonAttribute).map { $0 as! AXUIElement }
    if let v = close.flatMap({ attr($0, "AXEdited") }) as? Bool { print(v) } else { print("unknown") }
case "hit":
    var e: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(num(1)), Float(num(2)), &e) == .success,
          let el = e else { fail("nothing at point") }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    print(pid, attr(el, kAXRoleAttribute) as? String ?? "?")
case "texts":
    let app = AXUIElementCreateApplication(pidArg())
    for w in attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        let sub = attr(w, kAXSubroleAttribute) as? String ?? "?"
        walk(w) { e in
            if (attr(e, kAXRoleAttribute) as? String) == kAXStaticTextRole, let v = attr(e, kAXValueAttribute) as? String {
                print("\(sub): \(v)")
            }
        }
    }
case "menu-items":
    let app = AXUIElementCreateApplication(pidArg())
    guard let bar = attr(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { fail("no menu bar") }
    let want = args.count > 2 ? args[2] : ""
    guard let top = children(bar).first(where: { (attr($0, kAXTitleAttribute) as? String) == want }) else { fail("no menu \(want)") }
    for m in children(top) where (attr(m, kAXRoleAttribute) as? String) == kAXMenuRole {
        for item in children(m) {
            let t = attr(item, kAXTitleAttribute) as? String ?? ""
            print(t.isEmpty ? "-" : t)
        }
    }
case "menu":
    let app = AXUIElementCreateApplication(pidArg())
    guard var node = attr(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { fail("no menu bar") }
    for title in args.dropFirst(2) {
        // A menu bar item or menu item, looked up through the intermediate AXMenu.
        var found: AXUIElement?
        for c in children(node) {
            if (attr(c, kAXTitleAttribute) as? String) == title { found = c; break }
            if (attr(c, kAXRoleAttribute) as? String) == kAXMenuRole {
                for m in children(c) where (attr(m, kAXTitleAttribute) as? String) == title { found = m; break }
            }
            if found != nil { break }
        }
        guard let f = found else { fail("menu item not found: \(title)") }
        node = f
        if title != args.last {
            AXUIElementPerformAction(node, kAXPressAction as CFString)
            usleep(300_000)
        }
    }
    guard AXUIElementPerformAction(node, kAXPressAction as CFString) == .success else { fail("press failed") }
case "press":
    let app = AXUIElementCreateApplication(pidArg())
    let title = args.count > 2 ? args[2] : ""
    var target: AXUIElement?
    for w in attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] where target == nil {
        walk(w) { e in
            if target == nil, (attr(e, kAXRoleAttribute) as? String) == kAXButtonRole,
               (attr(e, kAXTitleAttribute) as? String) == title { target = e }
        }
    }
    guard let t = target else { fail("button not found: \(title)") }
    AXUIElementPerformAction(t, kAXPressAction as CFString)
case "click":
    let p = CGPoint(x: num(1), y: num(2))
    let count = args.count > 3 ? Int64(args[3]) ?? 1 : 1
    mouse(.mouseMoved, p)
    for i in 1...count {
        mouse(.leftMouseDown, p, clicks: i)
        mouse(.leftMouseUp, p, clicks: i)
    }
case "drag":
    let a = CGPoint(x: num(1), y: num(2)), b = CGPoint(x: num(3), y: num(4))
    mouse(.mouseMoved, a)
    mouse(.leftMouseDown, a)
    usleep(200_000)
    for i in 1...20 {
        let t = CGFloat(i) / 20
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        usleep(20_000)
    }
    usleep(200_000)
    mouse(.leftMouseUp, b)
case "type":
    let text = Array((args.count > 1 ? args[1] : "").utf16)
    for unit in text {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            var u = unit
            e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            post(e)
        }
    }
case "key":
    guard let raw = Int(args.count > 1 ? args[1] : "") else { fail("keycode") }
    let code = CGKeyCode(raw)
    var flags: CGEventFlags = []
    for m in args.dropFirst(2) {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        case "opt": flags.insert(.maskAlternate)
        default: fail("modifier \(m)")
        }
    }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = flags
        post(e)
    }
case "source-get":
    let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let id = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID)).takeUnretainedValue()
    print(id)
case "source-set":
    let want = args.count > 1 ? args[1] : ""
    let filter = [kTISPropertyInputSourceID as String: want] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], let s = list.first else {
        fail("input source not enabled: \(want)")
    }
    guard TISSelectInputSource(s) == noErr else { fail("select failed") }
case "default-browser":
    print(NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        .flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "")
default:
    fail("unknown command \(cmd)")
}
