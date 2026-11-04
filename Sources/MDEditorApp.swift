import SwiftUI

@main
struct MDEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual
    @AppStorage(ZoomPreference.key) private var zoom: Double = ZoomPreference.defaultValue

    /// ~1100×800 pt, but never larger than the visible area of the main screen.
    static var defaultWindowSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1100, height: 800)
        return CGSize(width: min(1100, visible.width - 40), height: min(800, visible.height - 40))
    }

    var body: some Scene {
        // No SwiftUI-owned window: the single main window belongs to AppDelegate (Finder opens, close prompts).
        // The scene is here for the menu commands only.
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appSettings) {}
            CommandGroup(replacing: .newItem) {
                Button("New") { appDelegate.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { appDelegate.openDocument() }
                    .keyboardShortcut("o", modifiers: .command)
                OpenRecentMenu { appDelegate.targetWindow().open([$0]) }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { appDelegate.closeTab() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Save") { appDelegate.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { appDelegate.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { EditorController.forKeyWindow()?.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { EditorController.forKeyWindow()?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(before: .toolbar) {
                Toggle("Visual", isOn: Binding(get: { mode == .visual }, set: { _ in mode = .visual }))
                    .keyboardShortcut("1", modifiers: .command)
                Toggle("Source", isOn: Binding(get: { mode == .source }, set: { _ in mode = .source }))
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { if let next = ZoomPreference.next(after: zoom) { zoom = next } }
                    .keyboardShortcut("=", modifiers: .command)
                    .help("Add a table row or raise a heading with Option-Command-Equals")
                    .disabled(ZoomPreference.next(after: zoom) == nil)
                Button("Zoom Out") { if let previous = ZoomPreference.previous(before: zoom) { zoom = previous } }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Delete a table row or lower a heading with Option-Command-Minus")
                    .disabled(ZoomPreference.previous(before: zoom) == nil)
                Button("Actual Size") { zoom = ZoomPreference.defaultValue }
                    .keyboardShortcut("0", modifiers: .command)
                Menu("Zoom") {
                    ForEach(ZoomPreference.steps, id: \.self) { step in
                        Toggle(ZoomPreference.label(step), isOn: Binding(
                            get: { ZoomPreference.snap(zoom) == step }, set: { _ in zoom = step }))
                    }
                }
                Divider()
            }
            // ⇧⌘] / ⇧⌘[ do the same: MainWindowController takes all four keys before the page (TB-8).
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Show Previous Tab") { appDelegate.targetStore().activatePrevious() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Show Next Tab") { appDelegate.targetStore().activateNext() }
                    .keyboardShortcut(.tab, modifiers: .control)
            }
        }
    }
}

/// File > Open Recent: the system list of the app (`NSDocumentController.recentDocumentURLs`), published for the menu.
@MainActor
final class RecentDocuments: ObservableObject {
    static let shared = RecentDocuments()
    @Published private(set) var urls: [URL] = NSDocumentController.shared.recentDocumentURLs

    func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        urls = NSDocumentController.shared.recentDocumentURLs
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
    }
}

private struct OpenRecentMenu: View {
    @ObservedObject private var recents = RecentDocuments.shared
    let open: (URL) -> Void

    var body: some View {
        Menu("Open Recent") {
            ForEach(recents.urls, id: \.self) { url in
                Button(url.lastPathComponent) { open(url) }
            }
            Divider()
            Button("Clear Menu") { recents.clear() }
                .disabled(recents.urls.isEmpty)
        }
    }
}
