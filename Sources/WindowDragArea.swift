import AppKit
import SwiftUI

/// The empty part of the tab bar moves the window, like the title bar; a double click there does what a double
/// click on the title bar does (`AppleActionOnDoubleClick`). Not `isMovableByWindowBackground`: that would move
/// the window while text is selected in the editor. Not `WindowDragGesture`: macOS 15+, we target 14.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch WindowDragArea.doubleClickAction(UserDefaults.standard) {
                case .zoom: window.performZoom(nil)
                case .minimize: window.performMiniaturize(nil)
                case .none: break
                }
                return
            }
            window.performDrag(with: event)
        }
    }

    enum DoubleClickAction: Equatable { case zoom, minimize, none }

    /// System Settings ▸ Desktop & Dock ▸ "Double-click a window's title bar to". Unset: Zoom (the system default).
    /// "Fill" (macOS 15) has no public API; Zoom is the closest.
    static func doubleClickAction(_ defaults: UserDefaults) -> DoubleClickAction {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        case "Maximize", "Fill": return .zoom
        default: return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? .minimize : .zoom
        }
    }
}
