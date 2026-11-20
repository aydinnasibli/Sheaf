import SwiftUI

/// Shown while a PDF in iCloud Drive downloads to this Mac, before it opens.
/// It waits as long as the download takes; after a while it says why it's
/// still waiting. Cancel goes back (the download may go on in iCloud).
struct DownloadingView: View {
    let download: OpenDocument.Download?
    /// "Cancel" in the main window; the PDF's own window closes.
    let cancelTitle: String
    let onCancel: () -> Void

    /// How long before the view explains that it's still waiting.
    static let patience: Duration = .seconds(8)

    @State private var isSlow = false

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Downloading from iCloud\u{2026}")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
            if let detail = Self.detail(for: download, isSlow: isSlow) {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .transition(.opacity)
            }
            SecondaryButton(title: cancelTitle, action: onCancel)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Counted from when the download started, also when coming back to it.
            let remaining = Self.patience - .seconds(Date.now.timeIntervalSince(download?.startedAt ?? .now))
            if remaining > .zero {
                do { try await Task.sleep(for: remaining) } catch { return }
            }
            withAnimation(Theme.hoverAnimation) { isSlow = true }
        }
    }

    /// Why it's taking a while, once it has.
    static func detail(for download: OpenDocument.Download?, isSlow: Bool) -> String? {
        if let problem = download?.problem {
            return "iCloud hasn\u{2019}t been able to download it yet (\(problem)). Sheaf keeps trying."
        }
        guard isSlow else { return nil }
        if download?.isTransferring == true {
            return "Still downloading. A big PDF can take a while; it opens by itself once it\u{2019}s here."
        }
        return "Waiting for iCloud. If this Mac is offline, the PDF opens once it\u{2019}s back online and the file is here."
    }
}
