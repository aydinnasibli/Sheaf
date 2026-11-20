import SwiftUI

/// A strip across the top of the window while the library has a problem:
/// it couldn't be saved, or it couldn't be opened and this session uses a
/// temporary one. Nothing shows otherwise.
struct LibraryNotice: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if library.saveError != nil {
                    Button { library.save() } label: {
                        Text("Try Again")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.control, lineWidth: 1))
                    }
                    .buttonStyle(.sheaf(cornerRadius: 7))
                    .help("Save the library again")
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.field)
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    private var message: String? {
        if let error = library.saveError { return error }
        if library.isTemporaryLibrary {
            return "Sheaf couldn\u{2019}t open your library, so it\u{2019}s using a temporary one: highlights you make now won\u{2019}t be kept after you quit, and PDF files aren\u{2019}t changed."
        }
        return nil
    }
}
