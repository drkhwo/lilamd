import SwiftUI
import WebKit

/// One tab's editor. The web view is the tab's own (`OpenDocument.makeController`), created on first show
/// and kept while the tab is hidden, so undo history and scroll position survive tab switches (TB-17).
struct EditorView: NSViewRepresentable {
    let document: OpenDocument
    var mode: EditorMode
    var zoom: Double
    var isActive: Bool
    var openFiles: ([URL]) -> Void

    @MainActor final class Coordinator {
        var wasActive = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let controller = document.makeController(mode: mode, zoom: zoom)
        let container = NSView()
        controller.webView.frame = container.bounds
        controller.webView.autoresizingMask = [.width, .height]
        container.addSubview(controller.webView)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let controller = document.controller else { return }
        controller.onOpenFiles = openFiles
        controller.setZoom(zoom) // every tab, hidden ones too (TB-26)
        view.isHidden = !isActive
        defer { context.coordinator.wasActive = isActive }
        guard isActive else { return }
        // Switching the mode recreates Vditor and drops its undo history: only the visible tab follows it now,
        // a hidden tab gets the mode when it is shown again.
        controller.setMode(mode)
        if !context.coordinator.wasActive { controller.focus() }
    }
}

/// The main window's content: tab bar over the editors of the tabs shown so far.
struct TabbedWindow: View {
    @ObservedObject var store: TabStore
    var openFiles: ([URL]) -> Void
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual
    @AppStorage(ZoomPreference.key) private var zoom: Double = ZoomPreference.defaultValue

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(store: store, openFiles: openFiles)
            Divider()
            ZStack {
                // Creation order, never reordered: moving a tab never re-parents a web view.
                ForEach(store.documents.filter { store.shown.contains($0.id) }) { doc in
                    EditorView(document: doc, mode: mode, zoom: ZoomPreference.snap(zoom),
                               isActive: doc.id == store.activeID, openFiles: openFiles)
                }
            }
            // Fills the window also with no editor yet (the window keeps its size, it does not shrink to the content).
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    Text("Visual").tag(EditorMode.visual)
                    Text("Source").tag(EditorMode.source)
                }
                .pickerStyle(.segmented)
                .help("Visual (⌘1) / Source (⌘2)")
            }
        }
    }
}
