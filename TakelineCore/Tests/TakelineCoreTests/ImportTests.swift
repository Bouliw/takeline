import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
@testable import TakelineCore

@Suite struct ImportTests {
    @Test func stripsMarkdownAndSplitsPages() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "takeline-test.md")
        try """
        ---
        title: Draft
        ---
        # Intro
        Hello **world**, see [the site](https://example.com).
        - first point
        <!-- note to self -->

        ---
        Second *page* with `code`.
        """.write(to: url, atomically: true, encoding: .utf8)
        let pages = try ScriptImport.pages(from: url)
        #expect(pages == ["Intro\nHello world, see the site.\nfirst point", "Second page with code."])
    }

    @Test func readsTextFilesFromWindowsToo() throws {
        let utf8 = FileManager.default.temporaryDirectory.appending(path: "takeline-test.txt")
        try Data("\u{FEFF}Première page.\r\nDeuxième ligne.\u{0C}\r\nPage deux.".utf8).write(to: utf8)
        #expect(try ScriptImport.pages(from: utf8) == ["Première page.\nDeuxième ligne.", "Page deux."])
        let utf16 = FileManager.default.temporaryDirectory.appending(path: "takeline-test-utf16.txt")
        try #require("Été".data(using: .utf16)).write(to: utf16)  // with a byte order mark, as Notepad saves "Unicode"
        #expect(try ScriptImport.pages(from: utf16) == ["Été"])
    }

    @Test func readsWordFiles() throws {
        #if canImport(AppKit)
        let url = FileManager.default.temporaryDirectory.appending(path: "takeline-test.docx")
        let text = NSAttributedString(string: "Première page.\nDeuxième ligne.")
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url)
        let pages = try ScriptImport.pages(from: url)
        #expect(pages == ["Première page.\nDeuxième ligne."])
        #endif
    }
}
