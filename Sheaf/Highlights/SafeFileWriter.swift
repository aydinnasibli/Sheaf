import Foundation

/// Replaces a file's contents so that a crash, a full disk or an unplugged
/// drive partway through can't leave it half-written: the new version is
/// written next to it first (in a temporary folder on the same drive) and
/// then swapped in, in one step.
///
/// The sandbox lets Sheaf write the files she picks but not always their
/// folders, so swapping may not be allowed. Then the file is written in
/// place, as Sheaf did before. That's never done when the drive is full:
/// writing in place then could cut the file short.
///
/// If the swap fails partway, after the original was moved aside, the
/// original is put back before anything else. After a failed swap, the
/// temporary folder is deleted only once the original is known to be back
/// where it belongs (the same file, by its file number): until then it may
/// hold the only copy of the file.
nonisolated enum SafeFileWriter {
    /// The steps that change the file, replaceable in tests.
    struct Steps: Sendable {
        /// Swaps the file at the first URL for the one at the second.
        var swap: @Sendable (_ url: URL, _ replacement: URL) throws -> Void
        /// Writes the file where it is.
        var writeInPlace: @Sendable (_ data: Data, _ url: URL) throws -> Void

        static let system = Steps(
            swap: { url, replacement in
                _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement, backupItemName: nil, options: [])
            },
            writeInPlace: { data, url in try data.write(to: url) }
        )
    }

    static func replace(_ url: URL, with data: Data, steps: Steps = .system) throws {
        let fileManager = FileManager.default
        let folder: URL
        do {
            folder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        } catch {
            // No temporary folder Sheaf may use on that drive.
            if isOutOfSpace(error) { throw error }
            try steps.writeInPlace(data, url)
            return
        }

        let temporary = folder.appending(path: url.lastPathComponent)
        do {
            // If this fails (the drive is full or gone), the file is untouched.
            try writeDurably(data, to: temporary)
        } catch {
            // Nothing was moved yet: the folder holds only the new version.
            try? fileManager.removeItem(at: folder)
            throw error
        }

        let original = FileIdentity(of: url)
        do {
            try steps.swap(url, temporary)
        } catch {
            try recover(url, original: original, data: data, temporary: temporary, error: error, steps: steps)
            return
        }
        try? fileManager.removeItem(at: folder)
    }

    /// After a failed swap: puts the original back if it was moved aside,
    /// then writes the file in place (unless the drive is full).
    private static func recover(
        _ url: URL, original: FileIdentity?, data: Data, temporary: URL, error: Error, steps: Steps
    ) throws {
        let folder = temporary.deletingLastPathComponent()
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)

        if fileManager.fileExists(atPath: path) {
            let now = FileIdentity(of: url)
            if let original, now == original {
                // The swap didn't touch the file: the folder only holds
                // copies of the new version.
                try? fileManager.removeItem(at: folder)
            } else if original != nil, now != nil {
                // Another file is in its place: the new version, if the swap
                // got that far. The original may be in the folder, so it stays.
                NSLog("Sheaf: a file swap failed partway (\(error)); kept \(folder.path(percentEncoded: false))")
                if (try? Data(contentsOf: url)) == data { return }
                throw error
            }
            // Otherwise there's no telling which file it is: it's written
            // in place, and the folder stays.
        } else if let aside = findOriginal(original, after: error, in: folder) {
            // The original was moved aside: put it back first.
            do {
                try fileManager.moveItem(at: aside, to: url)
            } catch {
                NSLog("Sheaf: couldn\u{2019}t put \(url.lastPathComponent) back after a failed save; it\u{2019}s at \(aside.path(percentEncoded: false))")
                throw error
            }
            if let original, FileIdentity(of: url) == original {
                try? fileManager.removeItem(at: folder)
            }
        } else {
            // The original can't be found. The folder stays, in case it's
            // there after all, and the new version (checked already) goes in
            // its place, so the PDF isn't missing.
            NSLog("Sheaf: \(url.lastPathComponent) went missing during a failed save (\(error)); kept \(folder.path(percentEncoded: false))")
            if (try? fileManager.moveItem(at: temporary, to: url)) != nil { return }
        }

        if isOutOfSpace(error) { throw error }
        try steps.writeInPlace(data, url)
    }

    /// The key under which a failed `replaceItemAt` says where it left the
    /// original, when that's neither where it was nor the temporary folder.
    /// (Foundation documents it by name only.)
    static let originalLocationKey = "NSFileOriginalItemLocationKey"

    /// Where the original went when a swap failed: where the error says,
    /// or the item in the temporary folder that is the original file.
    private static func findOriginal(_ original: FileIdentity?, after error: Error, in folder: URL) -> URL? {
        let fileManager = FileManager.default
        if let location = (error as NSError).userInfo[originalLocationKey] as? URL,
           fileManager.fileExists(atPath: location.path(percentEncoded: false)) {
            return location
        }
        guard let original else { return nil }
        let items = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let item = items?.nextObject() as? URL {
            if FileIdentity(of: item) == original { return item }
        }
        return nil
    }

    /// Writes the file and makes sure it has reached the disk, so the swap
    /// can't put a file in place whose contents are still in memory.
    private static func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(ENOSPC) || error.code == Int(EDQUOT)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}

/// Which file is at a path: its drive and file number, which stay the same
/// when it's moved or renamed on that drive, and its size and date.
nonisolated struct FileIdentity: Equatable {
    let volume: Int
    let fileNumber: Int
    let size: Int64
    let modified: Date?

    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let volume = (attributes[.systemNumber] as? NSNumber)?.intValue,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue
        else { return nil }
        self.volume = volume
        self.fileNumber = fileNumber
        self.size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        self.modified = attributes[.modificationDate] as? Date
    }
}
