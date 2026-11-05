import AppKit

/// Watches a tab's file for changes made by other apps (TESTS C7). A clean tab takes the disk version;
/// a tab with unsaved edits is asked (by its owner), so nothing is lost silently.
@MainActor
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var url: URL?
    private var pending: DispatchWorkItem?
    /// Bytes the app last read or wrote (not the current text): our own saves are never "foreign" (TB-25).
    var knownData: () -> Data? = { nil }
    var isDirty: () -> Bool = { false }
    /// Clean document: take the disk version.
    var reload: (Data) -> Void = { _ in }
    /// Dirty document: ask (the tab shows the sheet now or when it becomes active).
    var conflict: (Data) -> Void = { _ in }

    func watch(_ newURL: URL?) {
        guard newURL != url else { return }
        url = newURL
        pending?.cancel()
        pending = nil
        restart()
    }

    private func restart() {
        source?.cancel()
        source = nil
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed(src.data) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func changed(_ events: DispatchSource.FileSystemEvent) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.url != nil else { return }
                // Atomic saves replace the file: watch the new inode.
                if events.contains(.delete) || events.contains(.rename) { self.restart() }
                self.check()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func check() {
        guard let url, let disk = try? Data(contentsOf: url), disk != knownData() else { return }
        let dirty = isDirty()
        log.info("file changed on disk: \(url.path, privacy: .public), edited=\(dirty)")
        if dirty { conflict(disk) } else { reload(disk) }
    }

    static let keepResponse = NSApplication.ModalResponse.alertFirstButtonReturn
    static let reloadResponse = NSApplication.ModalResponse.alertSecondButtonReturn

    /// The safe choice ("Keep My Version") is the default button (Return) and has the keyboard focus
    /// (Space); the destructive "Reload from Disk" has no key equivalent and must be clicked.
    static func makeConflictAlert(fileName: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(fileName)” was changed by another app."
        alert.informativeText = "You have unsaved changes in LilaMD. Reload the file from disk (your changes are lost) or keep your version (saving will ask before overwriting)?"
        let keep = alert.addButton(withTitle: "Keep My Version")
        let reload = alert.addButton(withTitle: "Reload from Disk")
        keep.keyEquivalent = "\r"
        reload.keyEquivalent = ""
        alert.window.initialFirstResponder = keep
        return alert
    }
}
