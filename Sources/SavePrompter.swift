import AppKit

enum CloseChoice { case save, discard, cancel }
enum OverwriteChoice { case overwrite, cancel }
enum SaveReason { case explicit, autosave }

/// Every question the tab model asks the user. The app shows sheets (`AlertPrompter`);
/// tests pass a fake with fixed answers, so close and quit flows run without clicks.
@MainActor
protocol SavePrompting: AnyObject {
    /// A dirty tab is closing or the app is quitting: Save / Don't Save / Cancel.
    func askToSave(_ doc: OpenDocument) async -> CloseChoice
    /// The file on disk differs from the bytes the tab last read or wrote.
    func askOverwrite(_ doc: OpenDocument) async -> OverwriteChoice
    /// Save panel for Untitled and Save As; nil = cancelled.
    func chooseSaveURL(for doc: OpenDocument) async -> URL?
    /// `FileWatcher.makeConflictAlert`: Keep My Version / Reload from Disk.
    func showConflict(_ doc: OpenDocument) async -> NSApplication.ModalResponse
    func report(_ error: Error, for doc: OpenDocument) async
}

/// Sheets on the main window (app-modal alerts when there is no window).
@MainActor
final class AlertPrompter: SavePrompting {
    /// The window the sheets attach to.
    var window: () -> NSWindow? = { NSApp.mainWindow }

    func askToSave(_ doc: OpenDocument) async -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(doc.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        let dontSave = alert.addButton(withTitle: "Don’t Save")
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: "Cancel")
        switch await run(alert) {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// The safe choice (Cancel) is the default button, as in the conflict alert.
    func askOverwrite(_ doc: OpenDocument) async -> OverwriteChoice {
        let alert = NSAlert()
        alert.messageText = "“\(doc.displayName)” was changed by another app."
        alert.informativeText = "The file on disk is not the version LilaMD opened or saved. Overwrite it with your version?"
        alert.addButton(withTitle: "Cancel")
        let overwrite = alert.addButton(withTitle: "Overwrite")
        overwrite.keyEquivalent = ""
        return await run(alert) == .alertSecondButtonReturn ? .overwrite : .cancel
    }

    func chooseSaveURL(for doc: OpenDocument) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdownText]
        panel.nameFieldStringValue = doc.url?.lastPathComponent ?? "\(doc.displayName).md"
        if let dir = doc.url?.deletingLastPathComponent() { panel.directoryURL = dir }
        let response: NSApplication.ModalResponse
        if let window = window() {
            response = await withCheckedContinuation { done in panel.beginSheetModal(for: window) { done.resume(returning: $0) } }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    func showConflict(_ doc: OpenDocument) async -> NSApplication.ModalResponse {
        await run(FileWatcher.makeConflictAlert(fileName: doc.url?.lastPathComponent ?? doc.displayName))
    }

    func report(_ error: Error, for doc: OpenDocument) async {
        _ = await run(NSAlert(error: error))
    }

    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = window() else { return alert.runModal() }
        return await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
    }
}
