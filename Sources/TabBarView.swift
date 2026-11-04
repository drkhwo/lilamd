import SwiftUI

/// The strip of tabs above the editor: file name (truncated in the middle), a dot for unsaved changes,
/// × on hover. Click activates, × closes like ⌘W. Tabs are dragged to reorder; files dropped here open as tabs.
struct TabBarView: View {
    @ObservedObject var store: TabStore
    var openFiles: ([URL]) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(store.tabs) { doc in
                    TabItem(store: store, document: doc, isActive: doc.id == store.activeID,
                            isOnly: store.order.count == 1, isLast: store.order.last == doc.id)
                    Divider()
                }
            }
        }
        .frame(height: 28)
        .background(.bar)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            openFiles(files)
            return true
        }
    }
}

/// What a dragged tab carries: its id with a prefix, so `EditorWebView` refuses it as text.
enum TabDrag {
    static let prefix = "lilamd-tab:"

    static func payload(_ id: OpenDocument.ID) -> String { prefix + id.uuidString }

    static func id(from payload: String) -> OpenDocument.ID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}

private struct TabItem: View {
    let store: TabStore
    @ObservedObject var document: OpenDocument
    let isActive: Bool
    let isOnly: Bool
    let isLast: Bool
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 4) {
            // One slot for × (hover) and the unsaved dot, so the name does not move.
            ZStack {
                if hovering {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Close Tab")
                } else if document.isDirty {
                    Circle().frame(width: 7, height: 7).foregroundStyle(.secondary)
                }
            }
            .frame(width: 14, height: 14)
            Text(document.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer(minLength: 14)
        }
        .padding(.leading, 6)
        .frame(minWidth: 90, maxWidth: 200, maxHeight: .infinity)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(alignment: .leading) {
            if targeted { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.activate(document.id) }
        .onHover { hovering = $0 }
        .help(document.url?.path ?? document.displayName)
        .contextMenu { menu }
        .draggable(TabDrag.payload(document.id)) {
            Text(document.displayName).padding(4)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.compactMap(TabDrag.id).first else { return false }
            moveTab(moved)
            return true
        } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var menu: some View {
        Button("Close") { close() }
        Button("Close Others") { Task { await store.closeOthers(document.id) } }
            .disabled(isOnly)
        Button("Close Tabs to the Right") { Task { await store.closeToTheRight(document.id) } }
            .disabled(isLast)
        Divider()
        Button("Reveal in Finder") {
            if let url = document.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .disabled(document.url == nil)
        Button("Copy Path") {
            guard let url = document.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        .disabled(document.url == nil)
    }

    private func close() { Task { await store.close(document.id) } }

    /// The dragged tab takes this tab's place (TB-14).
    private func moveTab(_ id: OpenDocument.ID) {
        guard id != document.id, let from = store.order.firstIndex(of: id),
              let to = store.order.firstIndex(of: document.id) else { return }
        store.move(fromOffsets: [from], toOffset: from < to ? to + 1 : to)
    }
}
