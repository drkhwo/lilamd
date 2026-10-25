import WebKit
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "local.mdeditor", category: "editor")

/// Serves `mdedit://app/<path>` from the app bundle and `mdedit://doc/<path>` from the folder of the
/// open document (relative images). Nothing else is reachable; every request is logged.
@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdedit"

    let resourceRoot: URL
    var documentDirectory: URL?
    var onRequest: ((URL, Int) -> Void)?

    init(resourceRoot: URL = Bundle.main.resourceURL!, documentDirectory: URL?) {
        self.resourceRoot = resourceRoot
        self.documentDirectory = documentDirectory
    }

    func fileURL(for url: URL) -> URL? {
        let path = url.path(percentEncoded: false)
        let base: URL?
        switch url.host() {
        case "app": base = resourceRoot
        case "doc": base = documentDirectory
        default: base = nil
        }
        guard let base else { return nil }
        let root = base.standardizedFileURL
        let file = root.appending(path: String(path.drop(while: { $0 == "/" }))).standardizedFileURL
        guard file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { return nil }
        return file
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var status = 404
        var data = Data()
        if let file = fileURL(for: url), let contents = try? Data(contentsOf: file) {
            status = 200
            data = contents
        }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = [
            "Content-Type": status == 200 ? mime : "text/plain",
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
        ]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
        onRequest?(url, status)
        if status != 200 { log.info("scheme \(url.absoluteString, privacy: .public) -> \(status)") }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
