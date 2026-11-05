// Prints "<CGWindowID> <width> <count>" of the frontmost on-screen normal window of the given app, or nothing.
// <count> is the number of the app's on-screen normal windows: one main window holds every tab (R3).
import CoreGraphics
import Foundation
let owner = CommandLine.arguments.dropFirst().first ?? "LilaMD"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
if let w = windows.first, let id = w[kCGWindowNumber as String] as? Int {
    let width = (w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Int ?? 0
    print(id, width, windows.count)
}
