import SwiftUI

/// A short note over the bottom of the page, such as why text can't be
/// selected on a scanned page. VoiceOver reads it out when it appears.
struct PageNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.sheaf(in: Circle()))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.control))
        .shadow(color: Theme.floatingShadow, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
        .onChange(of: text) { AccessibilityNotification.Announcement(text).post() }
    }
}
