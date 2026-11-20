import SwiftUI

/// Shown while a PDF in iCloud Drive downloads to this Mac, before it opens.
struct DownloadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Downloading from iCloud\u{2026}")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
