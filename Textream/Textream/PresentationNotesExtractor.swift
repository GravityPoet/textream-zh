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

        // Unzip using Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExtractionError.extractionFailed("Could not unzip PPTX file.")
        }

        let notesDir = tempDir.appendingPathComponent("ppt/notesSlides")
        guard fileManager.fileExists(atPath: notesDir.path) else {
            throw ExtractionError.noNotesFound
        }

        let noteFiles = try fileManager.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xml" && $0.lastPathComponent.hasPrefix("notesSlide") }
            .sorted { file1, file2 in
                // Sort by slide number: notesSlide1.xml, notesSlide2.xml, ...
                let n1 = extractNumber(from: file1.lastPathComponent) ?? 0
                let n2 = extractNumber(from: file2.lastPathComponent) ?? 0
                return n1 < n2
            }

        var pages: [String] = []

        for noteFile in noteFiles {
            let data = try Data(contentsOf: noteFile)
            let text = parsePPTXNoteXML(data: data)
            pages.append(text)
        }

        // Filter out empty slides and slides that only have the slide number placeholder
        pages = pages.compactMap { page in
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && Int(trimmed) == nil else { return nil }
            return trimmed
        }

        guard !pages.isEmpty else {
            throw ExtractionError.noNotesFound
        }

        return pages
    }

    private static func extractNumber(from filename: String) -> Int? {
        let digits = filename.filter { $0.isNumber }
        return Int(digits)
    }

    private static func parsePPTXNoteXML(data: Data) -> String {
        let parser = PPTXNoteXMLParser(data: data)
        return parser.parse()
    }

    // MARK: - Keynote Extraction

    private static func extractKeynoteNotes(from url: URL) throws -> [String] {
        // Convert .key to .pptx via Keynote, then use the PPTX parser
        let pptxURL = try convertKeynoteToPPTX(from: url)
        defer { try? FileManager.default.removeItem(at: pptxURL) }
        return try extractPPTXNotes(from: pptxURL)
    }

    /// Use osascript to have Keynote export the .key file as .pptx
    private static func convertKeynoteToPPTX(from url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let pptxPath = tempDir.appendingPathComponent("export.pptx").path
        let escapedInput = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedOutput = pptxPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Keynote"
            activate
            open POSIX file "\(escapedInput)"
            delay 1
            set theDoc to front document
            export theDoc to POSIX file "\(escapedOutput)" as Microsoft PowerPoint
            close theDoc without saving
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            print("[Keynote] Export error: \(errOutput)")
            throw ExtractionError.extractionFailed("Failed to export Keynote to PPTX: \(errOutput)")
        }

        guard FileManager.default.fileExists(atPath: pptxPath) else {
            throw ExtractionError.extractionFailed("Keynote export did not produce a PPTX file.")
        }

        print("[Keynote] Exported to PPTX: \(pptxPath)")
        return URL(fileURLWithPath: pptxPath)
    }

    /// Extract notes directly from the .key ZIP package without launching Keynote
    private static func extractKeynoteNotesDirect(from url: URL) throws -> [String] {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // .key files are ZIP archives
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ExtractionError.extractionFailed("Could not unzip Keynote file.")
        }

        // List the top-level contents to find the right directory structure
        let topContents = (try? fileManager.contentsOfDirectory(atPath: tempDir.path)) ?? []
        print("[Keynote] Top-level contents: \(topContents)")

        // Find Index directory (may be at root or inside a subdirectory)
        var indexDir = tempDir.appendingPathComponent("Index")
        if !fileManager.fileExists(atPath: indexDir.path) {
            // Try looking in subdirectories
            for item in topContents {
                let candidate = tempDir.appendingPathComponent(item).appendingPathComponent("Index")
                if fileManager.fileExists(atPath: candidate.path) {
                    indexDir = candidate
                    break
                }
            }
        }

        guard fileManager.fileExists(atPath: indexDir.path) else {
            print("[Keynote] No Index directory found in: \(topContents)")
            throw ExtractionError.extractionFailed("Invalid Keynote file structure. No Index directory found.")
        }

        // List Index contents for debugging
        let indexContents = (try? fileManager.contentsOfDirectory(atPath: indexDir.path)) ?? []
        print("[Keynote] Index contents: \(indexContents)")

        // Also check for subdirectories within Index (e.g. Index/Slides/)
        let slidesDir = indexDir.appendingPathComponent("Slides")
        let searchDirs: [URL]
        if fileManager.fileExists(atPath: slidesDir.path) {
            searchDirs = [indexDir, slidesDir]
        } else {
            searchDirs = [indexDir]
        }

        // Collect Slide-*.iwa files from all search directories
        var iwaFiles: [URL] = []
        for dir in searchDirs {
            if let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.pathExtension == "iwa" && fileURL.lastPathComponent.hasPrefix("Slide-") {
                        iwaFiles.append(fileURL)
                    }
                }
            }
        }

        print("[Keynote] Found \(iwaFiles.count) Slide IWA files: \(iwaFiles.map { $0.lastPathComponent })")

        if iwaFiles.isEmpty {
            // If no Slide- files, try all .iwa files as fallback
            print("[Keynote] No Slide- files found, trying all .iwa files")
            if let enumerator = fileManager.enumerator(at: indexDir, includingPropertiesForKeys: nil) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.pathExtension == "iwa" {
                        iwaFiles.append(fileURL)
                        print("[Keynote] Found IWA: \(fileURL.lastPathComponent)")
                    }
                }
            }
        }

        iwaFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        // Decompress and extract protobuf strings per slide
        var perSlideStrings: [[String]] = []
        for iwaFile in iwaFiles {
            guard let data = try? Data(contentsOf: iwaFile) else {
                print("[Keynote] Could not read: \(iwaFile.lastPathComponent)")
                continue
            }
            print("[Keynote] Processing \(iwaFile.lastPathComponent): \(data.count) bytes, first 8 bytes: \(Array(data.prefix(8)).map { String(format: "%02X", $0) }.joined(separator: " "))")

            let decompressed = decompressIWA(data: data)
            print("[Keynote] Decompressed \(iwaFile.lastPathComponent): \(decompressed.count) bytes")

            let strings = extractProtobufStrings(from: decompressed)
            print("[Keynote] Extracted \(strings.count) strings from \(iwaFile.lastPathComponent): \(strings.prefix(5))")

            if !strings.isEmpty {
                perSlideStrings.append(strings)
            }
        }

        // UUID pattern
        let uuidPattern = try? NSRegularExpression(pattern: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

        // Combine strings per slide into pages — only keep natural language text
        var pages: [String] = []
        var seen: Set<String> = []
        for slideStrings in perSlideStrings {
            let meaningful = slideStrings.filter { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Must contain at least one space (natural language)
                guard t.contains(" ") && t.count >= 5 else { return false }
                // Skip UUIDs
                if let regex = uuidPattern, regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
                    return false
                }
                return true
            }
            let joined = meaningful.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty && !seen.contains(joined) {
                seen.insert(joined)
                pages.append(joined)
            }
        }

        print("[Keynote] Final pages count: \(pages.count)")

        guard !pages.isEmpty else {
            throw ExtractionError.noNotesFound
        }
        return pages
    }

    // MARK: - IWA Decompression

    /// IWA files use a chunked format: each chunk has 1 byte type + 3 bytes LE length
    /// Type 0x00 = Snappy compressed, Type 0x01 = uncompressed
    private static func decompressIWA(data: Data) -> Data {
        var result = Data()
        var offset = 0

        while offset < data.count {
            guard offset + 4 <= data.count else { break }
            let type = data[offset]
            let len = Int(data[offset + 1]) | (Int(data[offset + 2]) << 8) | (Int(data[offset + 3]) << 16)
            offset += 4

            guard offset + len <= data.count else { break }
            let chunk = data[offset..<(offset + len)]
            offset += len

            if type == 0x00 {
                // Snappy compressed
                if let decompressed = snappyDecompress(Data(chunk)) {
                    result.append(decompressed)
                }
            } else {
                // Uncompressed
                result.append(contentsOf: chunk)
            }
        }

        return result
    }

    /// Minimal Snappy block decompressor
    private static func snappyDecompress(_ data: Data) -> Data? {
        var pos = 0
        let bytes = [UInt8](data)
        let count = bytes.count

        // Read uncompressed length (varint)
        var uncompressedLength = 0
        var shift = 0
        while pos < count {
            let b = Int(bytes[pos])
            pos += 1
            uncompressedLength |= (b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }

        var output = Data(capacity: uncompressedLength)

        while pos < count && output.count < uncompressedLength {
            let tag = bytes[pos]
            pos += 1
            let type = tag & 0x03

            switch type {
            case 0x00: // Literal
                var length = Int(tag >> 2)
                if length < 60 {
                    length += 1
                } else {
                    let extraBytes = length - 59
                    guard pos + extraBytes <= count else { return output }
                    length = 1
                    for i in 0..<extraBytes {
                        length += Int(bytes[pos + i]) << (i * 8)
                    }
                    pos += extraBytes
                }
                guard pos + length <= count else { return output }
                output.append(contentsOf: bytes[pos..<(pos + length)])
                pos += length

            case 0x01: // Copy with 1-byte offset
                let length = Int((tag >> 2) & 0x07) + 4
                guard pos + 1 <= count else { return output }
                let offset = Int(tag >> 5) << 8 | Int(bytes[pos])
                pos += 1
                guard offset > 0 && offset <= output.count else { return output }
                for _ in 0..<length {
                    output.append(output[output.count - offset])
                }

            case 0x02: // Copy with 2-byte offset
                let length = Int(tag >> 2) + 1
                guard pos + 2 <= count else { return output }
                let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
                pos += 2
                guard offset > 0 && offset <= output.count else { return output }
                for _ in 0..<length {
                    output.append(output[output.count - offset])
                }

            case 0x03: // Copy with 4-byte offset
                let length = Int(tag >> 2) + 1
                guard pos + 4 <= count else { return output }
                let offset = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) |
                             (Int(bytes[pos + 2]) << 16) | (Int(bytes[pos + 3]) << 24)
                pos += 4
                guard offset > 0 && offset <= output.count else { return output }
                for _ in 0..<length {
                    output.append(output[output.count - offset])
                }

            default:
                return output
            }
        }

        return output
    }

    // MARK: - Protobuf String Extraction

    /// Extract all string fields from raw protobuf data
    private static func extractProtobufStrings(from data: Data) -> [String] {
        var strings: [String] = []
        var pos = 0
        let bytes = [UInt8](data)
        let count = bytes.count

        while pos < count {
            // Read field tag (varint)
            var tag = 0
            var shift = 0
            while pos < count {
                let b = Int(bytes[pos])
                pos += 1
                tag |= (b & 0x7F) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }

            let wireType = tag & 0x07

            switch wireType {
            case 0: // Varint
                while pos < count {
                    let b = bytes[pos]
                    pos += 1
                    if b & 0x80 == 0 { break }
                }
            case 1: // 64-bit
                pos += 8
            case 2: // Length-delimited (strings, bytes, embedded messages)
                var length = 0
                shift = 0
                while pos < count {
                    let b = Int(bytes[pos])
                    pos += 1
                    length |= (b & 0x7F) << shift
                    if b & 0x80 == 0 { break }
                    shift += 7
                }
                if length > 0 && pos + length <= count {
                    let fieldData = Data(bytes[pos..<(pos + length)])
                    // Try as UTF-8 string
                    if let str = String(data: fieldData, encoding: .utf8),
                       str.allSatisfy({ !$0.isASCII || ($0.isASCII && ($0 >= " " || $0 == "\n" || $0 == "\r" || $0 == "\t")) }) {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            strings.append(trimmed)
                        }
                    } else {
                        // Could be embedded message - recurse
                        let nested = extractProtobufStrings(from: fieldData)
                        strings.append(contentsOf: nested)
                    }
                    pos += length
                } else {
                    break // Malformed
                }
            case 5: // 32-bit
                pos += 4
            default:
                break // Unknown wire type, stop
            }
        }

        return strings
    }

    /// Fallback: use AppleScript to extract notes via Keynote app
    private static func extractKeynoteNotesAppleScript(from url: URL) throws -> [String] {
        let escapedPath = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Keynote"
            activate
            delay 2
            open POSIX file "\(escapedPath)"
            delay 2
            set theDoc to front document
            set notesList to {}
            repeat with aSlide in slides of theDoc
                set end of notesList to presenter notes of aSlide
            end repeat
            close theDoc without saving
            return notesList
        end tell
        """

        var errorDict: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            throw ExtractionError.extractionFailed(message)
        }

        guard let listResult = result else {
            throw ExtractionError.noNotesFound
        }

        var pages: [String] = []
        let count = listResult.numberOfItems
        for i in 1...count {
            let item = listResult.atIndex(i)
            let text = item?.stringValue ?? ""
            pages.append(text)
        }

        let meaningful = pages.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !meaningful.isEmpty else {
            throw ExtractionError.noNotesFound
        }

        return pages
    }
}

// MARK: - PPTX Notes XML Parser

private class PPTXNoteXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var texts: [String] = []
    private var currentText = ""
    private var insideBody = false
    private var insideTextRun = false
    private var skipPlaceholder = false
    private var currentPlaceholderType: String?

    init(data: Data) {
        self.data = data
    }

    func parse() -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return texts.joined(separator: "\n")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        // Track if we're inside the notes body (p:txBody inside p:sp that has notes placeholder)
        if elementName.hasSuffix(":sp") || elementName == "sp" {
            // Check placeholder type in child elements
            skipPlaceholder = false
            currentPlaceholderType = nil
        }

        if elementName.hasSuffix(":ph") || elementName == "ph" {
            let type = attributes["type"] ?? ""
            currentPlaceholderType = type
            // Skip slide number placeholders (type="sldNum") and slide image placeholders (type="sldImg")
            if type == "sldNum" || type == "sldImg" || type == "dt" || type == "hdr" || type == "ftr" {
                skipPlaceholder = true
            }
        }

        if elementName.hasSuffix(":txBody") || elementName == "txBody" {
            insideBody = true
        }

        if (elementName.hasSuffix(":t") || elementName == "t") && insideBody && !skipPlaceholder {
            insideTextRun = true
            currentText = ""
        }

        // Handle line breaks
        if (elementName.hasSuffix(":br") || elementName == "br") && insideBody && !skipPlaceholder {
            texts.append("")
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
            texts.append(currentText)
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
