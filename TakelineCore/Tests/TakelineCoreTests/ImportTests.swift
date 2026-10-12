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
