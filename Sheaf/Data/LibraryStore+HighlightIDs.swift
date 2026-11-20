import Foundation
import SwiftData

/// Each highlight's ID is its own across the whole library: it's how the
/// library, Spotlight, Undo and the PDF file (its `/SheafID` tag) find it.
/// Copies of one file, though, carry the same highlights with the same tags:
/// a PDF duplicated in Finder, or moved to another drive and added again.
/// A highlight coming in with an ID that's already taken gets a new one, and
/// its file is marked for saving, so the next save writes the new ID into it
/// in place of the old.
extension LibraryStore {
    /// IDs a highlight coming into `entry` can't have: every highlight's in
    /// the library, and those deleted from other PDFs that Undo could bring
    /// back.
    func takenHighlightIDs(besides entry: LibraryEntry) -> Set<UUID> {
        var records = FetchDescriptor<HighlightRecord>()
        records.propertiesToFetch = [\.id]
        var taken = Set(((try? context.fetch(records)) ?? []).map(\.id))
        var entries = FetchDescriptor<LibraryEntry>()
        entries.propertiesToFetch = [\.removedHighlightIDs]
        for other in (try? context.fetch(entries)) ?? [] where other.persistentModelID != entry.persistentModelID {
            taken.formUnion(other.removedHighlightIDs)
        }
        return taken
    }

    /// The ID for a highlight coming into `entry`: its own, unless that's
    /// taken. Then it's a new one, and the old one is taken out of the file
    /// at the next save, like a deleted highlight's, so the file doesn't
    /// keep it twice. `taken` gets the ID used.
    func uniqueHighlightID(_ id: UUID, comingInto entry: LibraryEntry, taken: inout Set<UUID>) -> UUID {
        guard taken.contains(id) else {
            taken.insert(id)
            return id
        }
        if !entry.removedHighlightIDs.contains(id) {
            entry.removedHighlightIDs.append(id)
        }
        entry.needsFileSave = true
        let fresh = UUID()
        taken.insert(fresh)
        return fresh
    }

    /// Gives a new ID to each highlight that shares its ID with another,
    /// as copies of one file could before Sheaf checked. The highlight in
    /// the PDF added to the library first keeps the ID; the others' files
    /// are marked for saving, so the next save writes their new IDs into
    /// them. Run as the library opens. Returns how many highlights changed.
    @discardableResult
    func repairDuplicateHighlightIDs() -> Int {
        var descriptor = FetchDescriptor<HighlightRecord>()
        descriptor.propertiesToFetch = [\.id]
        let records = (try? context.fetch(descriptor)) ?? []
        var seen = Set<UUID>()
        var shared = Set<UUID>()
        for record in records where !seen.insert(record.id).inserted {
            shared.insert(record.id)
        }
        guard !shared.isEmpty else { return 0 }

        var changed: [HighlightRecord] = []
        var reindexed: [HighlightRecord] = []
        for id in shared {
            let sharing = records.filter { $0.id == id }.sorted {
                ($0.entry?.addedAt ?? .distantFuture, $0.createdAt) < ($1.entry?.addedAt ?? .distantFuture, $1.createdAt)
            }
            for record in sharing.dropFirst() {
                record.id = UUID()
                if let entry = record.entry {
                    // The same PDF may still have a highlight with the old ID.
                    if !entry.highlights.contains(where: { $0.id == id }), !entry.removedHighlightIDs.contains(id) {
                        entry.removedHighlightIDs.append(id)
                    }
                    entry.needsFileSave = true
                }
                changed.append(record)
            }
            reindexed += sharing
        }
        save()
        NSLog("Sheaf: gave new IDs to \(changed.count) highlights that shared theirs with another PDF\u{2019}s.")
        // Spotlight had one item for each shared ID.
        searchIndex?.index(reindexed.compactMap(SpotlightHighlight.init))
        return changed.count
    }
}
