import CoreGraphics
import Foundation
import SwiftData

/// A user-made group of PDFs, shown in the library sidebar.
@Model
final class PDFCollection {
    var id = UUID()
    var name: String
    /// Index into `Theme.collectionColors`.
    var colorIndex: Int
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \LibraryEntry.collection)
    var items: [LibraryEntry] = []

    init(name: String, colorIndex: Int, now: Date = .now) {
        self.name = name
        self.colorIndex = colorIndex
        self.createdAt = now
    }
}
