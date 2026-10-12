//
//  PresentationNotesExtractor.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 9.02.2026.
//

import AppKit
import Foundation

enum PresentationNotesExtractor {

    enum ExtractionError: LocalizedError {
        case unsupportedFormat
        case extractionFailed(String)
        case noNotesFound

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Unsupported file format. Please drop a .pptx or .key file."
            case .extractionFailed(let detail):
                return "Failed to extract notes: \(detail)"
            case .noNotesFound:
                return "No presenter notes found in this presentation."
            }
        }
    }

    static func extractNotes(from url: URL) throws -> [String] {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pptx":
            return try extractPPTXNotes(from: url)
        default:
            throw ExtractionError.unsupportedFormat
        }
    }

    // MARK: - PPTX Extraction

    private static func extractPPTXNotes(from url: URL) throws -> [String] {
        // PPTX is a ZIP archive. Unzip to temp directory and parse XML notes.
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // Copy the security-scoped document into Textream's own temporary
        // directory before handing it to a child process. This keeps PPTX
        // import reliable inside the Mac App Store sandbox.
        let localArchive = tempDir.appendingPathComponent("presentation.pptx")
        do {
            try fileManager.copyItem(at: url, to: localArchive)
        } catch {
            throw ExtractionError.extractionFailed("Could not read PPTX file.")
        }

        // Unzip using Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", localArchive.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExtractionError.extractionFailed("Could not unzip PPTX file.")
        }

        // Notes file names don't follow the slide order. presentation.xml lists the
        // slides in order (p:sldIdLst), each r:id points to a slide part, and each
        // slide's relationships point to its notes part. Slides without notes are skipped.
        let pptDir = tempDir.appendingPathComponent("ppt")
        let slides = relationships(
            in: pptDir.appendingPathComponent("_rels/presentation.xml.rels"),
            partDir: pptDir,
            root: tempDir
        )
        let noteFiles: [URL] = XMLAttributesParser.attributes(
            of: "sldId",
            in: pptDir.appendingPathComponent("presentation.xml")
        ).compactMap { slideID in
            guard let relationshipID = slideID.first(where: { $0.key.hasSuffix(":id") })?.value,
                  let slide = slides.first(where: { $0.id == relationshipID })?.target else { return nil }
            let slideDir = slide.deletingLastPathComponent()
            return relationships(
                in: slideDir.appendingPathComponent("_rels/\(slide.lastPathComponent).rels"),
                partDir: slideDir,
                root: tempDir
            ).first(where: { $0.type.hasSuffix("/notesSlide") })?.target
        }

        var pages: [String] = []

        for noteFile in noteFiles {
            let data = try Data(contentsOf: noteFile)
            let text = parsePPTXNoteXML(data: data)
            pages.append(text)
        }

        // Filter out empty slides (the parser already drops the slide number placeholder)
        pages = pages.compactMap { page in
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }

        guard !pages.isEmpty else {
            throw ExtractionError.noNotesFound
        }

        return pages
    }

    private struct Relationship {
        let id: String
        let type: String
        let target: URL
    }

    /// Reads a .rels part. Relative targets resolve against the folder of the part the
    /// relationships belong to; targets outside the unzipped archive are ignored.
    private static func relationships(in relsFile: URL, partDir: URL, root: URL) -> [Relationship] {
        let rootPath = root.standardizedFileURL.path + "/"
        return XMLAttributesParser.attributes(of: "Relationship", in: relsFile).compactMap { attributes in
            guard let id = attributes["Id"], let target = attributes["Target"] else { return nil }
            let url = (target.hasPrefix("/")
                ? root.appendingPathComponent(String(target.dropFirst()))
                : partDir.appendingPathComponent(target)
            ).standardizedFileURL
            guard url.path.hasPrefix(rootPath) else { return nil }
            return Relationship(id: id, type: attributes["Type"] ?? "", target: url)
        }
    }

    private static func parsePPTXNoteXML(data: Data) -> String {
        let parser = PPTXNoteXMLParser(data: data)
        return parser.parse()
    }

    // MARK: - Keynote (not supported — handled via UI alerts)
}

// MARK: - PPTX Notes XML Parser

private class PPTXNoteXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var currentText = ""
    private var insideBody = false
    private var insideTextRun = false
    private var insideParagraph = false
    private var skipPlaceholder = false
    private var currentPlaceholderType: String?

    init(data: Data) {
        self.data = data
    }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return paragraphs.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName.hasSuffix(":sp") || elementName == "sp" {
            skipPlaceholder = false
            currentPlaceholderType = nil
        }

        if elementName.hasSuffix(":ph") || elementName == "ph" {
            let type = attributes["type"] ?? ""
            currentPlaceholderType = type
            if type == "sldNum" || type == "sldImg" || type == "dt" || type == "hdr" || type == "ftr" {
                skipPlaceholder = true
            }
        }

        if elementName.hasSuffix(":txBody") || elementName == "txBody" {
            insideBody = true
        }

        // Start of a paragraph
        if (elementName.hasSuffix(":p") || elementName == "p") && insideBody && !skipPlaceholder {
            insideParagraph = true
            currentParagraph = ""
        }

        if (elementName.hasSuffix(":t") || elementName == "t") && insideParagraph {
            insideTextRun = true
            currentText = ""
        }

        // Handle line breaks within a paragraph
        if (elementName.hasSuffix(":br") || elementName == "br") && insideParagraph {
            currentParagraph += "\n"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideTextRun {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if (elementName.hasSuffix(":t") || elementName == "t") && insideTextRun {
            insideTextRun = false
            currentParagraph += currentText
        }

        // End of a paragraph — flush it
        if (elementName.hasSuffix(":p") || elementName == "p") && insideParagraph {
            insideParagraph = false
            paragraphs.append(currentParagraph)
        }

        if elementName.hasSuffix(":txBody") || elementName == "txBody" {
            insideBody = false
        }

        if elementName.hasSuffix(":sp") || elementName == "sp" {
            skipPlaceholder = false
            currentPlaceholderType = nil
        }
    }
}

// MARK: - Element Attributes Parser

/// Collects the attributes of every element with a given name, ignoring its namespace prefix.
private class XMLAttributesParser: NSObject, XMLParserDelegate {
    private let name: String
    private var found: [[String: String]] = []

    private init(name: String) {
        self.name = name
    }

    static func attributes(of name: String, in url: URL) -> [[String: String]] {
        guard let parser = XMLParser(contentsOf: url) else { return [] }
        let collector = XMLAttributesParser(name: name)
        parser.delegate = collector
        parser.parse()
        return collector.found
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == name || elementName.hasSuffix(":" + name) {
            found.append(attributes)
        }
    }
}
