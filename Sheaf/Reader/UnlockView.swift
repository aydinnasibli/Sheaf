import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct UnlockView: View {
    /// Tries the password; returns false if it was wrong.
    let tryPassword: (String) -> Bool

    @State private var password = ""
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc")
                .font(.system(size: 44))
                .foregroundStyle(Theme.inkMuted)
            Text("This PDF Is Password-Protected")
                .font(Theme.display(20))
                .foregroundStyle(Theme.ink)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(unlock)
            if didFail {
                Text("That password didn\u{2019}t work. Try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            PrimaryButton(title: "Unlock", action: unlock)
                .disabled(password.isEmpty)
            Text("Highlights in password-protected PDFs are kept in Sheaf\u{2019}s library, not written into the file.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        if !tryPassword(password) {
            didFail = true
            password = ""
        }
    }
}
