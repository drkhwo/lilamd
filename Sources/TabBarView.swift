import SwiftUI

/// The strip of tabs above the editor: file name (truncated in the middle), a dot for unsaved changes,
/// × on hover. Click activates, × closes like ⌘W. Tabs are dragged to reorder; files dropped here open as tabs.
struct TabBarView: View {
    @ObservedObject var store: TabStore
    var openFiles: ([URL]) -> Void

    /// Width of the tabs; the rest of the visible strip is `WindowDragArea` (1.3).
    @State private var tabsWidth: CGFloat = 0

    var body: some View {
        GeometryReader { strip in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(store.tabs) { doc in
                                TabItem(store: store, document: doc, isActive: doc.id == store.activeID,
                                        isOnly: store.order.count == 1, isLast: store.order.last == doc.id)
                                    .id(doc.id)
                                Divider()
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                        // Next to the tabs, never under them: a tab drag must not move the window.
                        WindowDragArea()
                            .frame(width: max(0, strip.size.width - tabsWidth))
                    }
                }
                .onChange(of: store.activeID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .frame(height: 28)
        // A plain color, not `.bar`: the material is almost the page color and hid the active tab (1.1).
        .background(Color(nsColor: EditorPalette.stripBackground))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            openFiles(files)
            return true
        }
    }
}

/// The color of the editor page, shared by the page (`Resources/web/editor.css`, `body`) and the active tab,
/// so the active tab merges with the document: `#ffffff` in light, `#1d2125` in dark.
enum EditorPalette {
    static let pageBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1d / 255, green: 0x21 / 255, blue: 0x25 / 255, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}

extension EditorPalette {
    /// Behind the tabs: darker than the page in light (`#e8e8e8`), lighter in dark (`#2d3237`), so the active tab stands out.
    static let stripBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2d / 255, green: 0x32 / 255, blue: 0x37 / 255, alpha: 1)
            : NSColor(srgbRed: 0xe8 / 255, green: 0xe8 / 255, blue: 0xe8 / 255, alpha: 1)
    }
}

/// How a tab looks. A pure value, so tests check it without pixels and without a key window.
struct TabAppearance: Equatable {
    let isActive: Bool
    let isKeyWindow: Bool

    /// Active: the page color. Inactive: clear, the strip shows through.
    var backgroundNSColor: NSColor? { isActive ? EditorPalette.pageBackground : nil }
    /// 2 pt line at the top of the active tab: accent in the key window, gray otherwise. None on inactive tabs.
    var stripeNSColor: NSColor? { isActive ? (isKeyWindow ? .controlAccentColor : .tertiaryLabelColor) : nil }
    var weight: Font.Weight { isActive ? .semibold : .regular }

    var background: Color { backgroundNSColor.map(Color.init(nsColor:)) ?? .clear }
    var stripe: Color? { stripeNSColor.map(Color.init(nsColor:)) }
}

/// What the tab tells VoiceOver and UI scripts.
enum TabAccessibility {
    static func identifier(_ displayName: String) -> String { "tab:\(displayName)" }
    static func traits(isActive: Bool) -> AccessibilityTraits { isActive ? .isSelected : [] }
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

struct TabItem: View {
    let store: TabStore
    @ObservedObject var document: OpenDocument
    let isActive: Bool
    let isOnly: Bool
    let isLast: Bool
    @State private var hovering = false
    @State private var targeted = false
    @Environment(\.controlActiveState) private var controlActiveState

    private var appearance: TabAppearance { TabAppearance(isActive: isActive, isKeyWindow: controlActiveState == .key) }

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
            // The hidden semibold copy reserves the width, so the tab does not resize when it becomes active.
            ZStack {
                Text(document.displayName).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    .hidden().accessibilityHidden(true)
                Text(document.displayName).fontWeight(appearance.weight).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            Spacer(minLength: 14)
        }
        .padding(.leading, 6)
        .frame(minWidth: 90, maxWidth: 200, maxHeight: .infinity)
        .background(appearance.background)
        .overlay(alignment: .top) {
            if let stripe = appearance.stripe { Rectangle().fill(stripe).frame(height: 2) }
        }
        .overlay(alignment: .leading) {
            if targeted { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(document.displayName)
        .accessibilityIdentifier(TabAccessibility.identifier(document.displayName))
        .accessibilityAddTraits(TabAccessibility.traits(isActive: isActive))
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
