import SwiftUI

@main
struct MDEditorApp: App {
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentWindow(document: file.$document, fileURL: file.fileURL)
        }
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
