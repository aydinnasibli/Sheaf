import Foundation

/// Whether a file in iCloud Drive is on this Mac yet.
nonisolated enum CloudStatus: Sendable, Equatable {
    /// On this Mac: not in iCloud Drive, or downloaded. Reading it doesn't
    /// download anything.
    case local
    /// In iCloud Drive but not on this Mac. Reading it would download it.
    /// `isDownloading` while it's on its way.
    case notDownloaded(isDownloading: Bool)
    /// iCloud couldn't download it.
    case failed(String)

    var isLocal: Bool { self == .local }
}

/// Asks iCloud Drive about files, so Sheaf never downloads one by accident
/// (reading a file that isn't on the Mac downloads it). A protocol, so
/// tests can fake it.
nonisolated protocol CloudFiles: Sendable {
    func status(of url: URL) -> CloudStatus
    func startDownloading(_ url: URL)
}

/// The real iCloud Drive, through the file's resource values. These only
/// read the file's details, never its contents, so asking downloads nothing.
nonisolated struct ICloudDrive: CloudFiles {
    func status(of url: URL) -> CloudStatus {
        var url = url
        // Resource values are cached per URL; the status changes as it downloads.
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey,
        ]), values.isUbiquitousItem == true
        else { return .local }
        // `.downloaded` means an older version is here: still readable without waiting.
        guard values.ubiquitousItemDownloadingStatus == .notDownloaded else { return .local }
        if let error = values.ubiquitousItemDownloadingError {
            return .failed(error.localizedDescription)
        }
        return .notDownloaded(isDownloading: values.ubiquitousItemIsDownloading == true)
    }

    func startDownloading(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
