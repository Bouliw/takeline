import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Reads scripts from text files: plain text, Markdown and Word.
public enum ScriptImport {
    public enum ImportError: LocalizedError, Sendable {
        case unsupported(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unsupported(let ext): String(localized: "Can't read .\(ext) files.", bundle: .module)
            case .empty: String(localized: "The file has no text to read.", bundle: .module)
            }
        }
    }

    public static let extensions = ["txt", "md", "markdown", "docx"]

    /// The pages of the file. Markdown pages are separated by a line of `---`;
    /// a page break (form feed) separates pages in any format.
    public static func pages(from url: URL) throws -> [String] {
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "txt":
            var encoding = String.Encoding.utf8
            text = try String(contentsOf: url, usedEncoding: &encoding)
        case "md", "markdown":
            text = plainText(fromMarkdown: try String(contentsOf: url, encoding: .utf8))
        case "docx":
            #if canImport(AppKit)
            text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil).string
            #else
            throw ImportError.unsupported(ext)
            #endif
        default:
            throw ImportError.unsupported(ext)
        }
        let pages = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\u{0C}")
            .flatMap { ext == "md" || ext == "markdown" ? $0.components(separatedBy: pageRule) : [$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pages.isEmpty else { throw ImportError.empty }
        return pages
    }

    /// Marks a page break in Markdown converted to text.
    private static let pageRule = "\u{1E}"

    /// The text a reader would say: headings, lists and quotes keep their
    /// words, formatting marks, links' addresses, images, code fences, HTML
    /// comments and front matter go. Horizontal rules become page breaks.
    static func plainText(fromMarkdown markdown: String) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        var text = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^([-*_])( *\1){2,}$"#, options: .regularExpression) != nil { return pageRule }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return "" }
            var line = line
            for (pattern, template) in [
                (#"^\s{0,3}#{1,6}\s+"#, ""),          // headings
                (#"^\s*>\s?"#, ""),                    // quotes
                (#"^\s*([-*+]|\d+[.)])\s+"#, ""),      // list markers
                (#"!\[[^\]]*\]\([^)]*\)"#, ""),        // images
                (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),     // links
                (#"(\*\*|__)(.+?)\1"#, "$2"),          // bold
                (#"(\*|_)(\S(?:.*?\S)?)\1"#, "$2"),    // italics
                (#"`([^`]*)`"#, "$1"),                 // inline code
                (#"~~(.+?)~~"#, "$1"),                 // strikethrough
            ] {
                line = line.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
            return line
        }.joined(separator: "\n")
        text = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        return text
    }
}
