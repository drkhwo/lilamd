import SwiftUI

@main
struct MDEditorApp: App {
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual

    /// ~1100×800 pt, but never larger than the visible area of the main screen.
    static var defaultWindowSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1100, height: 800)
        return CGSize(width: min(1100, visible.width - 40), height: min(800, visible.height - 40))
    }

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentWindow(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(Self.defaultWindowSize) // later sizes are remembered by the system (window restoration)
        .commands {
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
        }
    }
}
