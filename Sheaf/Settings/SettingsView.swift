import SwiftUI

/// Sheaf > Settings (⌘,). Tabs along the top, as in other Mac apps: Reading
/// and Updates. Settings take effect right away; there's nothing to save.
struct SettingsView: View {
    @State private var reading: ReadingSettings

    init(workspace: Workspace) {
        _reading = State(initialValue: ReadingSettings { workspace.documents.compactMap(\.model) })
    }

    var body: some View {
        TabView {
            Tab("Reading", systemImage: "book") {
                ReadingSettingsPane(settings: reading)
            }
            Tab("Updates", systemImage: "arrow.triangle.2.circlepath") {
                UpdatesSettingsPane(updater: Updater.shared)
            }
        }
        .scenePadding()
        .frame(width: 500)
        .background(Theme.background)
    }
}

/// Page layout, zoom, book spreads and dark pages for the PDFs you open.
private struct ReadingSettingsPane: View {
    @Bindable var settings: ReadingSettings

    var body: some View {
        Form {
            Picker("Page layout:", selection: $settings.layout) {
                ForEach(ReaderModel.PageLayout.allCases) { layout in
                    Text(layout.menuTitle).tag(layout)
                }
            }
            .fixedSize()

            Picker("Zoom:", selection: $settings.zoomMode) {
                Text("Fit Page").tag(ReaderModel.ZoomMode.fitPage)
                Text("Fit Width").tag(ReaderModel.ZoomMode.fitWidth)
            }
            .pickerStyle(.radioGroup)

            Spacer().frame(height: 4)

            SettingsToggle(
                "Book spreads (cover on its own)",
                isOn: $settings.showsBookSpreads,
                caption: "In the two-page layouts, the cover stands alone, so the pages after it pair up like a printed book\u{2019}s."
            )
            .disabled(!settings.layout.showsPairs)

            SettingsToggle(
                "Dark pages in Dark Mode",
                isOn: $settings.darkPages,
                caption: "While your Mac is in Dark Mode, pages turn dark gray with light text. Highlights keep their colors."
            )

            Text("These are also in the View menu. A change here applies to the PDFs you have open, too.")
                .settingsCaption()
                .padding(.top, 10)
        }
        .formStyle(.columns)
    }
}

/// Automatic update checks, and checking now.
private struct UpdatesSettingsPane: View {
    @Bindable var updater: Updater

    var body: some View {
        Form {
            LabeledContent("Version:") {
                Text(Self.version)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }

            Spacer().frame(height: 4)

            SettingsToggle(
                "Check for updates automatically",
                isOn: $updater.automaticallyChecksForUpdates,
                caption: "Sheaf looks for a new version when it opens and every hour, and asks before installing it. Your library, highlights and notes are kept."
            )

            LabeledContent {
                VStack(alignment: .leading, spacing: 6) {
                    SecondaryButton(title: "Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Text(lastCheckText)
                        .settingsCaption()
                }
                .padding(.top, 6)
            } label: {
                EmptyView()
            }
        }
        .formStyle(.columns)
    }

    private var lastCheckText: String {
        guard updater.isAvailable else {
            return "Builds run from Xcode don\u{2019}t check for updates."
        }
        guard let date = updater.lastCheckDate else { return "Not checked yet." }
        return "Last checked \(date.formatted(.relative(presentation: .named)))."
    }

    /// "0.1.0 (42)": the version and the build number.
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A checkbox with a line or two of explanation under it, as in Apple's own
/// settings windows.
private struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    let caption: String

    init(_ title: String, isOn: Binding<Bool>, caption: String) {
        self.title = title
        self._isOn = isOn
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
            Text(caption)
                .settingsCaption()
                // Lines up with the checkbox's title, not the box.
                .padding(.leading, 20)
        }
        .padding(.bottom, 6)
    }
}

private extension View {
    func settingsCaption() -> some View {
        font(.system(size: 11.5))
            .foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320, alignment: .leading)
    }
}
