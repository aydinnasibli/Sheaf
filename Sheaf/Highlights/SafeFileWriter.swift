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
nonisolated enum SafeFileWriter {
    static func replace(_ url: URL, with data: Data) throws {
        let fileManager = FileManager.default
        let folder: URL
        do {
            folder = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        } catch {
            // No temporary folder Sheaf may use on that drive.
            if isOutOfSpace(error) { throw error }
            try data.write(to: url)
            return
        }
        defer { try? fileManager.removeItem(at: folder) }

        let temporary = folder.appending(path: url.lastPathComponent)
        // If this fails (the drive is full or gone), the file is untouched.
        try writeDurably(data, to: temporary)
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } catch {
            if isOutOfSpace(error) { throw error }
            try data.write(to: url)
        }
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
