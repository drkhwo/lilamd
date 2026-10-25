import XCTest
@testable import MDEditor

/// TESTS.md section A.
final class DocumentTests: XCTestCase {
    func testA1_readWriteWithoutChangesKeepsBytes() throws {
        for name in ["sample.md", "big.md", "cyrillic.md", "crlf.md", "empty.md"] {
            let data = try Samples.data(name)
            XCTAssertEqual(try MarkdownDocument(data: data).data(), data, name)
        }
    }

    func testA1_bomIsKept() throws {
        let data = MarkdownDocument.utf8BOM + Data("# Hi\n".utf8)
        let doc = try MarkdownDocument(data: data)
        XCTAssertEqual(doc.text, "# Hi\n")
        XCTAssertEqual(doc.data(), data)
    }

    func testA2_modifyWriteRead() throws {
        var doc = try MarkdownDocument(data: Samples.data("sample.md"))
        doc.text = doc.text.replacingOccurrences(of: "Last paragraph", with: "Changed paragraph")
        let reread = try MarkdownDocument(data: doc.data())
        XCTAssertEqual(reread.text, doc.text)
        XCTAssertTrue(reread.text.contains("Changed paragraph of the sample."))
    }

    func testA3_cyrillicAndEmojiRoundTrip() throws {
        let data = try Samples.data("cyrillic.md")
        let doc = try MarkdownDocument(data: data)
        XCTAssertTrue(doc.text.contains("съешь же ещё"))
        XCTAssertTrue(doc.text.contains("👨‍👩‍👧"))
        XCTAssertEqual(doc.data(), data)
        var edited = doc
        edited.text += "Новая строка 🎉\n"
        XCTAssertEqual(try MarkdownDocument(data: edited.data()).text, edited.text)
    }

    func testA4_emptyFile() throws {
        let doc = try MarkdownDocument(data: Data())
        XCTAssertEqual(doc.text, "")
        XCTAssertEqual(doc.data(), Data())
    }

    func testA5_crlfIsKept() throws {
        let data = try Samples.data("crlf.md")
        var doc = try MarkdownDocument(data: data)
        XCTAssertEqual(doc.data(), data)
        doc.text = doc.text.replacingOccurrences(of: "Second paragraph", with: "Edited paragraph")
        let out = doc.data()
        XCTAssertEqual(out.count(of: [0x0D, 0x0A]), data.count(of: [0x0D, 0x0A]))
        XCTAssertFalse(String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testA6_latin1GivesReadableError() {
        let latin1 = "caf\u{E9} na\u{EF}ve\n".data(using: .isoLatin1)!
        XCTAssertThrowsError(try MarkdownDocument(data: latin1)) { error in
            XCTAssertEqual(error as? MarkdownDocumentError, .notUTF8)
            XCTAssertTrue((error as NSError).localizedDescription.contains("UTF-8"))
            XCTAssertNotNil((error as NSError).localizedFailureReason)
        }
    }

    func testA7_defaultModeIsVisualAndChoiceIsRemembered() throws {
        let suite = "mdeditor.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(EditorModePreference.load(from: defaults), .visual)
        EditorModePreference.save(.source, to: defaults)
        // A fresh defaults object = what the next launch reads.
        XCTAssertEqual(EditorModePreference.load(from: try XCTUnwrap(UserDefaults(suiteName: suite))), .source)
        EditorModePreference.save(.visual, to: defaults)
        XCTAssertEqual(EditorModePreference.load(from: defaults), .visual)
        XCTAssertEqual(EditorModePreference.key, "editorMode") // same key as @AppStorage in the app
    }
}

private extension Data {
    func count(of pattern: [UInt8]) -> Int {
        var n = 0, i = startIndex
        while let r = self[i...].firstRange(of: pattern) { n += 1; i = r.upperBound }
        return n
    }
}
