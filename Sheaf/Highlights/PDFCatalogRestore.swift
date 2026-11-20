import CoreGraphics
import Foundation

/// Puts back what PDFKit leaves out of a PDF's catalog when it saves: the
/// printed page numbers ("xii", "245"), the document's language, and how it
/// asks to be shown (viewer preferences, page mode and layout).
///
/// PDFKit writes a whole new file, with a catalog of its own. Sheaf leaves
/// that file as it is and appends a small *incremental update*, the way PDF
/// lets any app change a file: a new version of the catalog with those
/// entries copied from the original, a cross-reference section for it, and
/// a trailer pointing back to PDFKit's. PDF readers read the newest version.
///
/// It only does this when PDFKit's output looks as expected (a classic
/// cross-reference table and trailer, the catalog a plain dictionary), and
/// copies only values that can be written out in full inside the catalog:
/// what they refer to is copied in place, and nothing with a stream in it
/// is copied. Otherwise the output is used as it is, as before.
nonisolated enum PDFCatalogRestore {
    /// The catalog entries put back, when the original has them and
    /// PDFKit's output doesn't. (Not /OpenAction or JavaScript: those run
    /// things when the PDF opens. PDFKit keeps /MarkInfo whenever it keeps
    /// the tags it describes.)
    static let keys = ["PageLabels", "Lang", "ViewerPreferences", "PageMode", "PageLayout"]

    /// The entries of `original`'s catalog that `output` lacks, each as
    /// its key and its value written out as PDF.
    static func lostEntries(of original: CGPDFDocument, in output: CGPDFDocument) -> [(key: String, value: String)] {
        guard let source = original.catalog, let target = output.catalog else { return [] }
        var entries: [(key: String, value: String)] = []
        for key in keys where !contains(target, key) {
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(source, key, &object), let object else { continue }
            let value = key == "PageLabels" ? numberTree(object) : PDFObjectText.text(of: object)
            if let value { entries.append((key, value)) }
        }
        return entries
    }

    /// `output` with `entries` added to its catalog by an incremental
    /// update, or nil if `output` isn't laid out as expected.
    static func appending(_ entries: [(key: String, value: String)], to output: Data) -> Data? {
        guard !entries.isEmpty else { return nil }
        // Offsets below count from the start of the file.
        let bytes = output.startIndex == 0 ? output : Data(Array(output))
        guard let file = PDFFileLayout(bytes) else { return nil }

        // The catalog without its closing ">>", then the entries, then ">>".
        var catalog = Self.opened(file.catalog)
        for (key, value) in entries {
            catalog += " /\(key) \(value)"
        }
        catalog += " >>"
        // The trailer as it was, pointing back to PDFKit's table.
        let trailer = Self.opened(file.trailer) + " /Prev \(file.crossReferenceOffset) >>"

        var update = Data()
        if let last = bytes.last, last != 0x0A, last != 0x0D { update.append(0x0A) }
        let objectOffset = bytes.count + update.count
        guard append("\(file.root.number) \(file.root.generation) obj\n\(catalog)\nendobj\n", to: &update) else { return nil }
        let tableOffset = bytes.count + update.count
        // Each entry is exactly 20 bytes: offset, generation, "n", space, newline.
        let entry = String(format: "%010ld %05ld n \n", objectOffset, file.root.generation)
        guard append(
            "xref\n\(file.root.number) 1\n\(entry)trailer\n\(trailer)\nstartxref\n\(tableOffset)\n%%EOF\n",
            to: &update
        ) else { return nil }

        // The new table and catalog are where the update says they are.
        let result = bytes + update
        var check = PDFSyntaxScanner(data: result)
        check.position = tableOffset
        guard check.readKeyword() == "xref" else { return nil }
        check.position = objectOffset
        guard check.readInteger() == file.root.number, check.readInteger() == file.root.generation,
              check.readKeyword() == "obj"
        else { return nil }
        return result
    }

    /// A dictionary's text without its closing ">>" (or the space before it).
    private static func opened(_ dictionary: String) -> String {
        var text = dictionary
        text.removeLast(2)
        while text.last?.isWhitespace == true { text.removeLast() }
        return text
    }

    /// `output` with the catalog entries `original` had put back, and
    /// their keys, or nil when there's nothing to put back or it can't be
    /// done safely. The caller still checks the result before using it.
    static func restoring(from original: CGPDFDocument, into output: Data) -> (data: Data, keys: [String])? {
        guard let parsed = PDFContentCheck.document(from: output) else { return nil }
        let entries = lostEntries(of: original, in: parsed)
        guard let data = appending(entries, to: output) else { return nil }
        return (data, entries.map(\.key))
    }

    /// Whether `restored` opens in Core Graphics with every entry of
    /// `output`'s catalog plus the restored ones, and the same pages.
    static func isIntact(_ restored: Data, comparedWith output: Data, adding keys: [String]) -> Bool {
        guard let after = PDFContentCheck.document(from: restored), let before = PDFContentCheck.document(from: output),
              let afterCatalog = after.catalog, let beforeCatalog = before.catalog,
              after.numberOfPages == before.numberOfPages
        else { return false }
        return Set(Self.keys(of: afterCatalog)) == Set(Self.keys(of: beforeCatalog)).union(keys)
    }

    // MARK: Helpers

    /// A number tree (like the page labels') as one dictionary with every
    /// entry in key order. A tree can be split into nodes that are separate
    /// objects; copied into one, it needs none.
    private static func numberTree(_ object: CGPDFObjectRef) -> String? {
        var root: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &root), let root else { return nil }
        var pairs: [(key: Int, value: String)] = []
        guard collect(root, depth: 0, into: &pairs), !pairs.isEmpty else { return nil }
        var seen = Set<Int>()
        let sorted = pairs.sorted { $0.key < $1.key }.filter { seen.insert($0.key).inserted }
        return "<< /Nums [" + sorted.map { "\($0.key) \($0.value)" }.joined(separator: " ") + "] >>"
    }

    private static func collect(_ node: CGPDFDictionaryRef, depth: Int, into pairs: inout [(key: Int, value: String)]) -> Bool {
        guard depth < 16 else { return false }
        var nums: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Nums", &nums), let nums {
            let count = CGPDFArrayGetCount(nums)
            guard count % 2 == 0 else { return false }
            for index in stride(from: 0, to: count, by: 2) {
                var key: CGPDFInteger = 0
                var value: CGPDFObjectRef?
                guard CGPDFArrayGetInteger(nums, index, &key), key >= 0,
                      CGPDFArrayGetObject(nums, index + 1, &value), let value,
                      let text = PDFObjectText.text(of: value)
                else { return false }
                pairs.append((key, text))
            }
        }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(kids, index, &kid), let kid,
                      collect(kid, depth: depth + 1, into: &pairs)
                else { return false }
            }
        }
        return true
    }

    private static func contains(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object) && object != nil
    }

    private static func keys(of dictionary: CGPDFDictionaryRef) -> [String] {
        var keys: [String] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
            keys.append(String(cString: key))
            return true
        }, nil)
        return keys
    }

    /// Appends text whose characters are all bytes (Latin-1), byte for byte.
    private static func append(_ text: String, to data: inout Data) -> Bool {
        guard let bytes = text.data(using: .isoLatin1) else { return false }
        data.append(bytes)
        return true
    }
}

/// A PDF value written out as PDF text, with every part in full: what
/// Core Graphics reads through references is written in place.
nonisolated enum PDFObjectText {
    /// The longest value copied, so a strange file can't make a huge one.
    static let maxLength = 256 * 1024

    /// The value as PDF, or nil if it has a stream in it or is too large or deep.
    static func text(of object: CGPDFObjectRef) -> String? {
        var budget = maxLength
        return text(of: object, depth: 0, budget: &budget)
    }

    private static func text(of object: CGPDFObjectRef, depth: Int, budget: inout Int) -> String? {
        guard depth < 12, budget > 0 else { return nil }
        let result: String?
        switch CGPDFObjectGetType(object) {
        case .null:
            result = "null"
        case .boolean:
            var value: CGPDFBoolean = 0
            result = CGPDFObjectGetValue(object, .boolean, &value) ? (value != 0 ? "true" : "false") : nil
        case .integer:
            var value: CGPDFInteger = 0
            result = CGPDFObjectGetValue(object, .integer, &value) ? String(value) : nil
        case .real:
            var value: CGPDFReal = 0
            result = CGPDFObjectGetValue(object, .real, &value) && value.isFinite ? real(Double(value)) : nil
        case .name:
            var value: UnsafePointer<CChar>?
            result = CGPDFObjectGetValue(object, .name, &value) ? value.map(name) : nil
        case .string:
            var value: CGPDFStringRef?
            result = CGPDFObjectGetValue(object, .string, &value) ? value.map(hexString) : nil
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array else { return nil }
            var items: [String] = []
            for index in 0..<CGPDFArrayGetCount(array) {
                var item: CGPDFObjectRef?
                guard CGPDFArrayGetObject(array, index, &item), let item,
                      let text = text(of: item, depth: depth + 1, budget: &budget)
                else { return nil }
                items.append(text)
            }
            result = "[" + items.joined(separator: " ") + "]"
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
            // Keys written as names right away, byte for byte.
            var entries: [(key: String, value: CGPDFObjectRef)] = []
            CGPDFDictionaryApplyBlock(dictionary, { key, value, _ in
                entries.append((name(key), value))
                return true
            }, nil)
            var parts: [String] = []
            for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
                guard let text = text(of: value, depth: depth + 1, budget: &budget) else { return nil }
                parts.append(key + " " + text)
            }
            result = "<<" + parts.map { " " + $0 }.joined() + " >>"
        case .stream:
            // A stream can't be written out in place.
            result = nil
        @unknown default:
            result = nil
        }
        guard let result else { return nil }
        budget -= result.utf8.count
        return budget >= 0 ? result : nil
    }

    /// A real number without an exponent, which PDF doesn't allow.
    private static func real(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// A name, with "#xx" for bytes a name can't hold as they are.
    private static func name(_ pointer: UnsafePointer<CChar>) -> String {
        var text = "/"
        let delimiters = Set("()<>[]{}/%#".utf8)
        var cursor = pointer
        while cursor.pointee != 0 {
            let byte = UInt8(bitPattern: cursor.pointee)
            if byte < 0x21 || byte > 0x7E || delimiters.contains(byte) {
                text += String(format: "#%02X", byte)
            } else {
                text.append(Character(Unicode.Scalar(byte)))
            }
            cursor += 1
        }
        return text
    }

    /// A string as hex, so every byte is kept exactly (text in any encoding).
    private static func hexString(_ string: CGPDFStringRef) -> String {
        let length = CGPDFStringGetLength(string)
        guard length > 0, let bytes = CGPDFStringGetBytePtr(string) else { return "<>" }
        let buffer = UnsafeBufferPointer(start: bytes, count: length)
        return "<" + buffer.map { String(format: "%02X", $0) }.joined() + ">"
    }
}

/// The end of a PDF file as PDFKit writes it: its last cross-reference
/// table, its trailer and its catalog. `nil` for any other layout, such
/// as cross-reference streams or an encrypted file.
nonisolated struct PDFFileLayout {
    struct Reference: Equatable {
        let number: Int
        let generation: Int
    }

    /// Where the last cross-reference table starts.
    let crossReferenceOffset: Int
    /// The trailer dictionary, from "<<" to ">>", byte for byte (Latin-1).
    let trailer: String
    let root: Reference
    /// The catalog dictionary, from "<<" to ">>", byte for byte (Latin-1).
    let catalog: String

    init?(_ data: Data) {
        // Offsets in the file count from its first byte.
        guard data.startIndex == 0 else { return nil }
        var scanner = PDFSyntaxScanner(data: data)
        // "startxref", then the table's offset, near the end of the file.
        guard let start = scanner.lastIndex(of: "startxref", within: 2048) else { return nil }
        scanner.position = start + "startxref".utf8.count
        guard let tableOffset = scanner.readInteger(), tableOffset >= 0, tableOffset < data.count else { return nil }

        // The table: "xref", then sections of "first count" and entries.
        scanner.position = tableOffset
        guard scanner.readKeyword() == "xref" else { return nil }
        var offsets: [Int: (offset: Int, generation: Int)] = [:]
        while true {
            scanner.skipWhitespace()
            if scanner.peek(keyword: "trailer") {
                _ = scanner.readKeyword()
                break
            }
            guard let first = scanner.readInteger(), let count = scanner.readInteger(),
                  first >= 0, count >= 0, count <= 10_000_000
            else { return nil }
            for number in first..<(first + count) {
                guard let offset = scanner.readInteger(), let generation = scanner.readInteger(),
                      let kind = scanner.readKeyword(), kind == "n" || kind == "f"
                else { return nil }
                if kind == "n" { offsets[number] = (offset, generation) }
            }
        }

        // The trailer: only a plain one, from a file written in one go.
        scanner.skipWhitespace()
        guard let trailerRange = scanner.readDictionary(), let trailer = scanner.text(in: trailerRange) else { return nil }
        guard !trailer.contains("/Prev"), !trailer.contains("/XRefStm"), !trailer.contains("/Encrypt"),
              let match = trailer.firstMatch(of: /\/Root\s+(\d+)\s+(\d+)\s+R/),
              let number = Int(match.1), let generation = Int(match.2)
        else { return nil }
        let root = Reference(number: number, generation: generation)

        // The catalog: "number generation obj << … >> endobj".
        guard let location = offsets[number], location.generation == generation,
              location.offset >= 0, location.offset < data.count
        else { return nil }
        scanner.position = location.offset
        guard scanner.readInteger() == number, scanner.readInteger() == generation, scanner.readKeyword() == "obj" else { return nil }
        scanner.skipWhitespace()
        guard let catalogRange = scanner.readDictionary(), let catalog = scanner.text(in: catalogRange),
              scanner.readKeyword() == "endobj"
        else { return nil }

        self.crossReferenceOffset = tableOffset
        self.trailer = trailer
        self.root = root
        self.catalog = catalog
    }
}

/// Reads PDF syntax: just enough to find the trailer and the catalog.
nonisolated struct PDFSyntaxScanner {
    let data: Data
    var position: Int

    init(data: Data) {
        self.data = data
        self.position = data.startIndex
    }

    private var end: Int { data.endIndex }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        "()<>[]{}/%".utf8.contains(byte)
    }

    /// The start of the last `keyword` in the final `window` bytes.
    func lastIndex(of keyword: String, within window: Int) -> Int? {
        let pattern = Data(keyword.utf8)
        let lower = max(data.startIndex, end - window)
        return data.range(of: pattern, options: .backwards, in: lower..<end)?.lowerBound
    }

    /// Skips whitespace and comments.
    mutating func skipWhitespace() {
        while position < end {
            let byte = data[position]
            if Self.isWhitespace(byte) {
                position += 1
            } else if byte == UInt8(ascii: "%") {
                while position < end, data[position] != 0x0A, data[position] != 0x0D { position += 1 }
            } else {
                return
            }
        }
    }

    /// The next run of regular characters, like "xref", "obj" or "12".
    mutating func readKeyword() -> String? {
        skipWhitespace()
        let start = position
        while position < end, !Self.isWhitespace(data[position]), !Self.isDelimiter(data[position]) {
            position += 1
        }
        guard position > start else { return nil }
        return String(decoding: data[start..<position], as: UTF8.self)
    }

    func peek(keyword: String) -> Bool {
        var copy = self
        return copy.readKeyword() == keyword
    }

    mutating func readInteger() -> Int? {
        guard let word = readKeyword(), word.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(word)
    }

    /// The range of the dictionary starting here, from "<<" to its own
    /// ">>", skipping strings and nested dictionaries in it.
    mutating func readDictionary() -> Range<Int>? {
        skipWhitespace()
        let start = position
        guard starts(with: "<<") else { return nil }
        var depth = 0
        while position < end {
            let byte = data[position]
            if starts(with: "<<") {
                depth += 1
                position += 2
            } else if starts(with: ">>") {
                depth -= 1
                position += 2
                if depth == 0 { return start..<position }
            } else if byte == UInt8(ascii: "<") {
                // A hex string.
                guard let close = data[position...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
                position = close + 1
            } else if byte == UInt8(ascii: "(") {
                guard skipLiteralString() else { return nil }
            } else if byte == UInt8(ascii: "%") {
                skipWhitespace()
            } else {
                position += 1
            }
        }
        return nil
    }

    /// Skips "( … )", with nested parentheses and backslash escapes.
    private mutating func skipLiteralString() -> Bool {
        var depth = 0
        while position < end {
            let byte = data[position]
            position += 1
            if byte == UInt8(ascii: "\\") {
                position += 1
            } else if byte == UInt8(ascii: "(") {
                depth += 1
            } else if byte == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { return true }
            }
        }
        return false
    }

    private func starts(with text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard position + bytes.count <= end else { return false }
        return bytes.indices.allSatisfy { data[position + $0] == bytes[$0] }
    }

    /// The bytes in `range` as text, one character per byte.
    func text(in range: Range<Int>) -> String? {
        String(data: data[range], encoding: .isoLatin1)
    }
}
