// Helper for the FOREGROUND step 30 (live input in other languages). Compiled by `scripts/fg/30-ime-live.sh`:
// `swiftc -O scripts/fg/30-ime-live.swift -o <tmp>/imetool`. Input sources and one held key only; keys, clicks and
// activation come from `fgtool.swift`. It changes the input source: run only from the FOREGROUND.md batch.
//
//   enabled                 ids of the enabled keyboard input sources, sorted, one per line
//   current                 id of the current input source
//   exists <id>             "yes" if the system knows the source (selectable), else "no"; exit 1 on "no"
//   is-enabled <id>         "yes" | "no"
//   enable <id>             TISEnableInputSource; exit 1 if the system refuses
//   disable <id>            TISDisableInputSource
//   select <id>             TISSelectInputSource; exit 1 if the source is not enabled or selectable
//   hold <keycode> <seconds> [pick-keycode]
//                           key down, wait, optional second key (the accent picker), key up. The key does not auto-repeat:
//                           synthetic events do not start the press-and-hold picker on every macOS (the script treats that as inconclusive).
//   list                    every known source with enabled/selectable flags (evidence)
import ApplicationServices
import Carbon
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("no command") }

func prop(_ s: TISInputSource, _ k: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(s, k) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func flag(_ s: TISInputSource, _ k: CFString) -> Bool {
    guard let p = TISGetInputSourceProperty(s, k) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}
func sources(includeAll: Bool) -> [TISInputSource] {
    (TISCreateInputSourceList(nil, includeAll).takeRetainedValue() as? [TISInputSource]) ?? []
}
func source(_ id: String) -> TISInputSource? {
    sources(includeAll: true).first { prop($0, kTISPropertyInputSourceID) == id }
}
func idArg() -> String { args.count > 1 ? args[1] : fail("input source id expected") }

switch cmd {
case "enabled":
    let ids = sources(includeAll: false).compactMap { prop($0, kTISPropertyInputSourceID) }
    for id in Set(ids).sorted() { print(id) }
case "current":
    print(prop(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID) ?? "?")
case "exists":
    guard let s = source(idArg()), flag(s, kTISPropertyInputSourceIsSelectCapable) else { print("no"); exit(1) }
    print("yes")
case "is-enabled":
    guard let s = source(idArg()) else { print("no"); exit(0) }
    print(flag(s, kTISPropertyInputSourceIsEnabled) ? "yes" : "no")
case "enable":
    guard let s = source(idArg()) else { fail("unknown source \(idArg())") }
    guard TISEnableInputSource(s) == noErr else { fail("TISEnableInputSource refused \(idArg())") }
case "disable":
    guard let s = source(idArg()) else { fail("unknown source \(idArg())") }
    guard TISDisableInputSource(s) == noErr else { fail("TISDisableInputSource refused \(idArg())") }
case "select":
    guard let s = source(idArg()), flag(s, kTISPropertyInputSourceIsEnabled), flag(s, kTISPropertyInputSourceIsSelectCapable) else {
        fail("source \(idArg()) is not enabled or not selectable")
    }
    guard TISSelectInputSource(s) == noErr else { fail("TISSelectInputSource refused \(idArg())") }
case "hold":
    guard args.count >= 3, let code = UInt16(args[1]), let secs = Double(args[2]) else { fail("hold <keycode> <seconds> [pick-keycode]") }
    func key(_ c: UInt16, down: Bool) { CGEvent(keyboardEventSource: nil, virtualKey: c, keyDown: down)?.post(tap: .cghidEventTap); usleep(20_000) }
    key(code, down: true)
    Thread.sleep(forTimeInterval: secs)
    if args.count > 3, let pick = UInt16(args[3]) { key(pick, down: true); key(pick, down: false); Thread.sleep(forTimeInterval: 0.2) }
    key(code, down: false)
case "list":
    for s in sources(includeAll: true) {
        print(prop(s, kTISPropertyInputSourceID) ?? "?", "enabled=\(flag(s, kTISPropertyInputSourceIsEnabled))",
              "selectable=\(flag(s, kTISPropertyInputSourceIsSelectCapable))", "name=\(prop(s, kTISPropertyLocalizedName) ?? "?")")
    }
default:
    fail("unknown command \(cmd)")
}
