import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
}

enum MarkdownDocumentError: LocalizedError, Equatable {
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .notUTF8: return "This file is not UTF-8 text."
        }
    }

    var failureReason: String? {
        switch self {
        case .notUTF8:
            return "LilaMD only opens UTF-8 encoded Markdown. Convert the file to UTF-8 (for example with `iconv -f latin1 -t utf-8`) and open it again."
        }
    }
}

/// A Markdown file. `text` holds the file's exact characters (CRLF kept as is);
/// writing an unchanged document produces the bytes that were read.
struct MarkdownDocument: FileDocument {
    static let utf8BOM = Data([0xEF, 0xBB, 0xBF])
    static var readableContentTypes: [UTType] { [.markdownText] }

    var text: String
    var hasBOM: Bool

    init(text: String = "", hasBOM: Bool = false) {
        self.text = text
        self.hasBOM = hasBOM
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(data: configuration.file.regularFileContents ?? Data())
    }

    init(data: Data) throws {
        var body = data
        hasBOM = data.starts(with: Self.utf8BOM)
        if hasBOM { body = data.dropFirst(3) }
        guard let decoded = String(data: body, encoding: .utf8) else {
            throw MarkdownDocumentError.notUTF8
        }
        text = decoded
    }

    func data() -> Data {
        var out = hasBOM ? Self.utf8BOM : Data()
        out.append(Data(text.utf8))
        return out
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data())
    }
}
