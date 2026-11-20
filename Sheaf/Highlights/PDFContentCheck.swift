import CoreGraphics
import Foundation

/// Finds what a PDF has that PDFKit throws away when it saves, so Sheaf
/// doesn't rewrite those files. It reads the file with Core Graphics' own
/// PDF parser, which shows the file as it is rather than as PDFKit
/// understands it.
///
/// PDFKit writes a whole new file from what it understands. Tried on this
/// macOS, it drops files attached to the PDF and the data of file
/// attachment, sound, video and 3D annotations; with layers, it deletes
/// the content of hidden ones from the page (an exam's answers layer, say);
/// and portfolios and XFA forms don't survive either. Their highlights stay
/// in Sheaf's library, like a signed PDF's.
nonisolated enum PDFContentCheck {
    /// Something a PDFKit save would lose. In the order they're listed in.
    enum Loss: Int, Sendable, Hashable, CaseIterable {
        case attachments
        case layers
        case media
        case portfolio
        case xfaForm

        /// What she'd see in the PDF, as it reads in "This PDF has …".
        var description: String {
            switch self {
            case .attachments: "attached files"
            case .layers: "layers that can be shown or hidden"
            case .media: "embedded sound, video or 3D content"
            case .portfolio: "a portfolio of other files"
            case .xfaForm: "an XFA form"
            }
        }
    }

    /// "attached files and layers that can be shown or hidden", in the
    /// order of `Loss.allCases`.
    static func describe(_ losses: Set<Loss>) -> String {
        let parts = Loss.allCases.filter(losses.contains).map(\.description)
        guard let last = parts.last else { return "" }
        guard parts.count > 1 else { return last }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Core Graphics' reading of a PDF, or nil if it can't read it.
    static func document(from data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    /// What a PDFKit save of `document` would lose. Empty when it's safe to rewrite.
    static func losses(in document: CGPDFDocument) -> Set<Loss> {
        var losses = Set<Loss>()
        if let catalog = document.catalog {
            var names: CGPDFDictionaryRef?
            var embedded: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
               CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded,
               !isEmptyTree(embedded) {
                losses.insert(.attachments)
            }
            if has(catalog, "OCProperties") { losses.insert(.layers) }
            if has(catalog, "Collection") { losses.insert(.portfolio) }
            var form: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form, has(form, "XFA") {
                losses.insert(.xfaForm)
            }
        }
        // Pages count from 1 in Core Graphics.
        let pageCount = document.numberOfPages
        guard pageCount > 0 else { return losses }
        for number in 1...pageCount {
            guard let page = document.page(at: number)?.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations else { continue }
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                var subtype: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                      CGPDFDictionaryGetName(annotation, "Subtype", &subtype), let subtype
                else { continue }
                switch String(cString: subtype) {
                case "FileAttachment": losses.insert(.attachments)
                case "Sound", "Movie", "Screen", "RichMedia", "3D": losses.insert(.media)
                default: break
                }
            }
            if losses.isSuperset(of: [.attachments, .media]) { break }
        }
        return losses
    }

    /// Whether the PDF carries usage rights or certification (a /Perms
    /// entry): signatures Adobe Reader checks, which a rewrite breaks just
    /// like a signature field's.
    static func hasSignedPermissions(_ document: CGPDFDocument) -> Bool {
        guard let catalog = document.catalog else { return false }
        var perms: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Perms", &perms), let perms else { return false }
        return CGPDFDictionaryGetCount(perms) > 0
    }

    private static func has(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object) && object != nil
    }

    /// Whether a name tree (like the attached files') has no entries.
    private static func isEmptyTree(_ node: CGPDFDictionaryRef) -> Bool {
        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &names), let names, CGPDFArrayGetCount(names) > 0 { return false }
        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids, CGPDFArrayGetCount(kids) > 0 { return false }
        return true
    }
}
