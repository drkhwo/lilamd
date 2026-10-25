import SwiftUI
import WebKit

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    var mode: EditorMode
    var documentDirectory: URL?

    final class Coordinator {
        var controller: EditorController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let controller = EditorController(text: text, mode: mode, documentDirectory: documentDirectory)
        let binding = $text
        controller.onTextChange = { binding.wrappedValue = $0 }
        context.coordinator.controller = controller
        return controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        let binding = $text
        controller.onTextChange = { binding.wrappedValue = $0 }
        controller.setDocumentDirectory(documentDirectory)
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
        EditorView(text: $document.text, mode: mode, documentDirectory: fileURL?.deletingLastPathComponent())
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
