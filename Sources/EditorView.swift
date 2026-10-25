import SwiftUI
import WebKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    var mode: EditorMode
    var fileURL: URL?
    var fileData: () -> Data

    @MainActor final class Coordinator {
        var controller: EditorController?
        let watcher = FileWatcher()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let controller = EditorController(text: text, mode: mode, documentDirectory: fileURL?.deletingLastPathComponent())
        let binding = $text
        controller.onTextChange = { binding.wrappedValue = $0 }
        context.coordinator.controller = controller
        return controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        let binding = $text
        controller.onTextChange = { binding.wrappedValue = $0 }
        controller.setDocumentDirectory(fileURL?.deletingLastPathComponent())
        context.coordinator.watcher.view = nsView
        context.coordinator.watcher.currentData = fileData
        context.coordinator.watcher.watch(fileURL)
        controller.setMode(mode)
        // Text that did not come from the editor: revert, external change, Edit > Undo.
        if text != controller.text { controller.load(text: text) }
    }
}

struct DocumentWindow: View {
    @Binding var document: MarkdownDocument
    var fileURL: URL?
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual

    var body: some View {
        EditorView(text: $document.text, mode: mode, fileURL: fileURL, fileData: { [document] in document.data() })
            .frame(minWidth: 480, minHeight: 320)
            .onAppear {
                // Test hook for screenshots (TESTS C8) without changing the system setting:
                // `open -a "MD Editor" file.md --args -MDEditorAppearance dark`.
                switch UserDefaults.standard.string(forKey: "MDEditorAppearance") {
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                default: break
                }
            }
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
