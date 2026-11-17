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
        if !isActive { document.findBarDidDeactivate() }
        defer { context.coordinator.wasActive = isActive }
        guard isActive else { return }
        // Switching the mode recreates Vditor and drops its undo history: only the visible tab follows it now,
        // a hidden tab gets the mode when it is shown again.
        controller.setMode(mode)
        // After this update pass, not inside it: SwiftUI may update the new tab before it hides the old one
        // (a layout pass pulls it first), and hiding the old tab's editor then moves the focus to the toolbar.
        if !context.coordinator.wasActive && !document.isFindFieldFocused {
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.focus() } }
        }
    }
}

/// The main window's content: tab bar over the editors of the tabs shown so far.
struct TabbedWindow: View {
    @ObservedObject var store: TabStore
    @ObservedObject var historyStore: HistoryStore
    let sessionStore: SessionStore
    var openFiles: ([URL]) -> Void
    var openDocument: () -> Void
    var restoreSession: (RestorableSession) -> Void
    @AppStorage(EditorModePreference.key) private var mode: EditorMode = .visual
    @AppStorage(ZoomPreference.key) private var zoom: Double = ZoomPreference.defaultValue

    var body: some View {
        Group {
            if store.contentState == .startScreen {
                StartScreenView(
                    history: historyStore,
                    session: sessionStore,
                    newDocument: { store.newUntitled() },
                    openDocument: openDocument,
                    restoreSession: restoreSession,
                    openFile: { openFiles([$0]) }
                )
            } else {
                VStack(spacing: 0) {
                    TabBarView(store: store, openFiles: openFiles)
                    Divider()
                    if let active = store.active, active.isFindOpen {
                        FindBar(document: active)
                    }
                    ZStack {
                        // Creation order, never reordered: moving a tab never re-parents a WKWebView.
                        ForEach(store.documents.filter { store.shown.contains($0.id) }) { doc in
                            EditorView(document: doc, mode: mode, zoom: ZoomPreference.snap(zoom),
                                       isActive: doc.id == store.activeID, openFiles: openFiles)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            if store.contentState == .editor {
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
}

private struct FindBar: View {
    @ObservedObject var document: OpenDocument
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: Binding(
                get: { document.findQuery },
                set: { document.setFindQuery($0) }
            ))
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { document.findNext() }
            .onKeyPress(keys: [.return]) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                document.findPrevious()
                return .handled
            }
            .onKeyPress(.escape) {
                document.closeFind()
                return .handled
            }
            Group {
                if document.findQuery.isEmpty { Text("") }
                else if document.findCount == 0 { Text("Not found") }
                else {
                    Text(FindCounterPresentation.text(index: document.findIndex, count: document.findCount))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(minWidth: 76, alignment: .trailing)
            Button { document.findPrevious() } label: { Image(systemName: "chevron.up") }
                .help("Find Previous")
                .disabled(document.findCount == 0)
            Button { document.findNext() } label: { Image(systemName: "chevron.down") }
                .help("Find Next")
                .disabled(document.findCount == 0)
            Button("Done") { document.closeFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: EditorPalette.pageBackground))
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
        .onChange(of: focused) { _, value in document.setFindFieldFocused(value) }
        .onChange(of: document.id) { _, _ in
            focused = document.isFindFieldFocused
            document.setFindFieldFocused(focused)
        }
        .onChange(of: document.findFocusRequest) { _, _ in
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                }
            }
        }
    }
}

enum FindCounterPresentation {
    static func text(index: Int, count: Int) -> String {
        "\(index + 1) of \(count >= 10_000 ? "10000+" : String(count))"
    }
}
