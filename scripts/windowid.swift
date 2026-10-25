// Prints "<CGWindowID> <width>" of the frontmost on-screen normal window of the given app, or nothing.
import CoreGraphics
import Foundation
let owner = CommandLine.arguments.dropFirst().first ?? "MD Editor"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner && (w[kCGWindowLayer as String] as? Int) == 0 {
    let width = (w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Int ?? 0
    if let id = w[kCGWindowNumber as String] as? Int { print(id, width); break }
}
