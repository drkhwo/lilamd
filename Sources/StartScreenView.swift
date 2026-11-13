import SwiftUI

/// Pure presentation rules for the history list. Kept independent of SwiftUI focus and windows
/// so the list's grouping, filtering, and highlighted ranges can be tested in background mode.
struct StartScreenPresentation {
    let pinned: [HistoryRecord]
    let recent: [HistoryRecord]
    let query: String

    init(records: [HistoryRecord], query: String, fileExists: @escaping (HistoryRecord) -> Bool = { _ in true }) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = records.filter { record in
            guard !needle.isEmpty else { return true }
            return record.displayName.localizedCaseInsensitiveContains(needle)
                || record.path.localizedCaseInsensitiveContains(needle)
        }
        pinned = matching.filter(\.pinned).sorted { ($0.pinOrder ?? .max) < ($1.pinOrder ?? .max) }
        recent = HistoryStore.ordered(matching.filter { !$0.pinned })
        self.query = needle
        self.fileExists = fileExists
    }

    private let fileExists: (HistoryRecord) -> Bool
    var isEmpty: Bool { pinned.isEmpty && recent.isEmpty }
    func exists(_ record: HistoryRecord) -> Bool { fileExists(record) }
    var missing: [HistoryRecord] { (pinned + recent).filter { !fileExists($0) } }
    static func restoreButtonTitle(for session: RestorableSession) -> String? {
        session.files.isEmpty ? nil : "Restore last session · \(session.files.count) \(session.files.count == 1 ? "tab" : "tabs")"
    }

    func matchRanges(in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive], range: cursor..<text.endIndex) {
            ranges.append(range)
            cursor = range.upperBound
        }
        return ranges
    }
}

/// Small callback boundary shared by the view and callback tests.
struct StartScreenActions {
    var newDocument: () -> Void
    var openDocument: () -> Void
    var restoreSession: (RestorableSession) -> Void
    var openFile: (URL) -> Void

    func createNew() { newDocument() }
    func showOpenPanel() { openDocument() }
    func restore(_ session: RestorableSession) { restoreSession(session) }
    func open(_ url: URL) { openFile(url) }
}

struct StartScreenView: View {
    @ObservedObject var history: HistoryStore
    let session: SessionStore
    let actions: StartScreenActions
    @State private var query = ""
    @State private var alwaysReopen: Bool
    @State private var pendingMissing: HistoryRecord?
    @State private var selectedID: HistoryRecord.ID?
    @FocusState private var searchFocused: Bool

    init(history: HistoryStore, session: SessionStore, newDocument: @escaping () -> Void,
         openDocument: @escaping () -> Void, restoreSession: @escaping (RestorableSession) -> Void,
         openFile: @escaping (URL) -> Void) {
        self.history = history
        self.session = session
        actions = StartScreenActions(newDocument: newDocument, openDocument: openDocument,
                                     restoreSession: restoreSession, openFile: openFile)
        _alwaysReopen = State(initialValue: session.alwaysReopenTabs)
    }

    private var restorable: RestorableSession { session.restorableSession() }
    private var presentation: StartScreenPresentation {
        StartScreenPresentation(records: history.records, query: query, fileExists: history.fileExists)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: EditorPalette.stripBackground)).frame(height: 28)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 14) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 34, weight: .regular)).foregroundStyle(Color.accentColor)
                        Text("LilaMD").font(.system(size: 24, weight: .semibold))
                        HStack(spacing: 12) {
                            Button("New") { actions.createNew() }.keyboardShortcut("n", modifiers: .command)
                            Button("Open…") { actions.showOpenPanel() }.keyboardShortcut("o", modifiers: .command)
                        }
                        .controlSize(.large)
                        if let restoreTitle = StartScreenPresentation.restoreButtonTitle(for: restorable) {
                            Button(restoreTitle) { actions.restore(restorable) }
                                .controlSize(.large)
                            if restorable.missingCount > 0 {
                                Text("\(restorable.missingCount) \(restorable.missingCount == 1 ? "file" : "files") not found")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Always reopen my tabs", isOn: Binding(get: { alwaysReopen }, set: {
                            alwaysReopen = $0
                            session.setAlwaysReopenTabs($0)
                        }))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    }
                    .padding(.top, 64).padding(.bottom, 34)

                    if !history.records.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search recent files", text: $query)
                                .textFieldStyle(.plain).focused($searchFocused)
                                .onSubmit {
                                    if let selected = selectedRecord { activate(selected) }
                                    else if let first = presentation.pinned.first ?? presentation.recent.first { activate(first) }
                                }
                                .onKeyPress(.escape) { query = ""; return .handled }
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear Search")
                            }
                            Text("⌘F").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color(nsColor: EditorPalette.stripBackground).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 20)
                    }

                    if !presentation.pinned.isEmpty {
                        section("PINNED", records: presentation.pinned)
                    }
                    if !presentation.recent.isEmpty {
                        section("RECENT", records: presentation.recent)
                    }
                    if !query.isEmpty && presentation.isEmpty {
                        Text("No files found").foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    if presentation.isEmpty && query.isEmpty {
                        Text("Drop a .md file here to open it")
                            .font(.callout).foregroundStyle(.secondary).padding(.top, 16)
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.bottom, 40)
            }
            .background(Color(nsColor: EditorPalette.pageBackground))
        }
        .background(Color(nsColor: EditorPalette.pageBackground))
        .frame(minWidth: 480, minHeight: 320)
        .onMoveCommand { direction in
            let rows = presentation.pinned + presentation.recent
            guard !rows.isEmpty else { return }
            let current = rows.firstIndex { $0.id == selectedID }
            switch direction {
            case .down: selectedID = rows[min((current ?? -1) + 1, rows.count - 1)].id
            case .up: selectedID = rows[max((current ?? rows.count) - 1, 0)].id
            default: break
            }
        }
        .onKeyPress(.return) {
            guard let selected = selectedRecord else { return .ignored }
            activate(selected)
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command), let selected = selectedRecord else { return .ignored }
            history.remove(selected.id)
            selectedID = nil
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL && ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            guard !files.isEmpty else { return false }
            files.forEach(actions.open)
            return true
        }
        .confirmationDialog("Remove from the list?", isPresented: Binding(
            get: { pendingMissing != nil }, set: { if !$0 { pendingMissing = nil } }
        ), presenting: pendingMissing) { record in
            Button("Remove from List", role: .destructive) { history.remove(record.id); pendingMissing = nil }
            Button("Cancel", role: .cancel) { pendingMissing = nil }
        }
        .onKeyPress(keys: [.init("f")]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            searchFocused = true
            return .handled
        }
    }

    @ViewBuilder private func section(_ title: String, records: [HistoryRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
                .padding(.bottom, 5)
            ForEach(records) { record in
                historyRow(record)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }

    private func historyRow(_ record: HistoryRecord) -> some View {
        let exists = presentation.exists(record)
        return HStack(spacing: 12) {
            if record.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            highlightedName(record.displayName).fontWeight(.medium).lineLimit(1)
            highlightedName(abbreviatedPath(record.directoryPath)).font(.callout).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(exists ? dateLabel(record.lastOpened) : "not found")
                .font(.caption).foregroundStyle(exists ? Color.secondary : Color.gray)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .foregroundStyle(exists ? Color.primary : Color.gray)
        .background(selectedID == record.id ? Color(nsColor: EditorPalette.stripBackground).opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { activate(record) }
        .onTapGesture(count: 2) { activate(record) }
        .contextMenu {
            Button("Open") { activate(record) }.disabled(!exists)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([history.url(for: record)]) }.disabled(!exists)
            Button(record.pinned ? "Unpin" : "Pin") { record.pinned ? history.unpin(record.id) : history.pin(record.id) }
            Button(record.pinned ? "Remove from List" : "Remove from Recent", role: .destructive) { history.remove(record.id) }
        }
        .help(record.path)
    }

    private func activate(_ record: HistoryRecord) {
        selectedID = record.id
        guard presentation.exists(record) else { pendingMissing = record; return }
        actions.open(history.url(for: record))
    }

    private var selectedRecord: HistoryRecord? {
        (presentation.pinned + presentation.recent).first { $0.id == selectedID }
    }

    private func highlightedName(_ name: String) -> Text {
        let ranges = presentation.matchRanges(in: name)
        guard !ranges.isEmpty else { return Text(name) }
        var result = Text("")
        var cursor = name.startIndex
        for range in ranges {
            if cursor < range.lowerBound { result = result + Text(name[cursor..<range.lowerBound]) }
            result = result + Text(name[range]).bold().foregroundColor(.accentColor)
            cursor = range.upperBound
        }
        if cursor < name.endIndex { result = result + Text(name[cursor...]) }
        return result
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today " + date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = calendar.isDate(date, equalTo: .now, toGranularity: .weekOfYear) ? "EEEE" : "d MMM"
        return formatter.string(from: date)
    }
}
