import AppKit

/// Watches the open file for changes made by other apps (TESTS C7). If the window has no unsaved edits,
/// the document is reverted to the disk version; otherwise the user is asked, so nothing is lost silently.
@MainActor
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var url: URL?
    private var pending: DispatchWorkItem?
    weak var view: NSView?
    /// Current document bytes, to tell our own saves from foreign changes.
    var currentData: () -> Data = { Data() }

    func watch(_ newURL: URL?) {
        guard newURL != url else { return }
        url = newURL
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
                guard let self else { return }
                // Atomic saves replace the file: watch the new inode.
                if events.contains(.delete) || events.contains(.rename) { self.restart() }
                self.check()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func check() {
        guard let url, let disk = try? Data(contentsOf: url), disk != currentData() else { return }
        guard let window = view?.window, let document = NSDocumentController.shared.document(for: window), let type = document.fileType else { return }
        log.info("file changed on disk: \(url.path, privacy: .public), edited=\(document.isDocumentEdited)")
        if !document.isDocumentEdited {
            try? document.revert(toContentsOf: url, ofType: type)
            return
        }
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” was changed by another app."
        alert.informativeText = "You have unsaved changes in MD Editor. Reload the file from disk (your changes are lost) or keep your version (saving will ask before overwriting)?"
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Reload from Disk")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { try? document.revert(toContentsOf: url, ofType: type) }
        }
    }
}
