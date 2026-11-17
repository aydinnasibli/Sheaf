import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct HighlightsPanel: View {
    @Bindable var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Highlights")
                    .font(Theme.display(18))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(model.highlights.count == 1 ? "1 in this PDF" : "\(model.highlights.count) in this PDF")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
            }

            HighlightFilterChips(model: model)

            if let block = model.fileWriteBlock {
                Label(block.explanation, systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.highlights.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.highlightGroups, id: \.page) { group in
                            SectionLabel(title: "Page \(group.page + 1)")
                                .padding(.top, 6)
                            ForEach(group.items) { record in
                                HighlightCard(record: record, model: model)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                export()
            } label: {
                Label("Export highlights as Markdown", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.control, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(model.highlights.isEmpty)
            .opacity(model.highlights.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.background)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No highlights yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Select text, then press 1\u{2013}4 or click a highlighter above. Pick a highlighter first to highlight as you select.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(model.title) highlights.md"
        let text = model.markdownExport()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The color filter chips with counts.
struct HighlightFilterChips: View {
    @Bindable var model: ReaderModel

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(HighlightKind.allCases) { kind in
                let isOn = model.panelFilter.contains(kind)
                Button {
                    if isOn { model.panelFilter.remove(kind) } else { model.panelFilter.insert(kind) }
                } label: {
                    Text("\(kind.name) \u{00B7} \(model.count(of: kind))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .fixedSize()
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .foregroundStyle(kind.chipText)
                        .background(kind.chipBackground, in: Capsule())
                        .overlay(Capsule().strokeBorder(isOn ? Theme.accent : .clear, lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(isOn ? "Show all colors" : "Show only \(kind.name)")
                .accessibilityLabel("\(kind.name), \(model.count(of: kind))")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// A highlight in the panel. Click the text to go to it; click the note
/// (or "Add note") to type a note right on the card.
struct HighlightCard: View {
    let record: HighlightRecord
    let model: ReaderModel

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovered = false
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Swatch(color: record.kind.swatch)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Button { model.go(to: record) } label: {
                    Text(record.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to this highlight")
                .accessibilityLabel("\(record.kind.name): \(record.text)")
                .accessibilityHint("Goes to this highlight")

                if isEditing {
                    TextField("Write a note\u{2026}", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1...6)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
                        .focused($isNoteFocused)
                        .onSubmit(commit)
                        .onExitCommand { isEditing = false }
                    Text("Return to save \u{00B7} Esc to cancel")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkMuted)
                } else if !record.note.isEmpty {
                    Button(action: startEditing) {
                        Text(record.note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.inkMuted)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit note")
                } else if isHovered {
                    Button(action: startEditing) {
                        Label("Add note", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isEditing ? Theme.control : Theme.border, lineWidth: 1))
        .onHover { isHovered = $0 }
        .onChange(of: isNoteFocused) { _, focused in
            if !focused && isEditing { commit() }
        }
        .contextMenu {
            Button(record.note.isEmpty ? "Add Note" : "Edit Note", action: startEditing)
            Menu("Change Color") {
                ForEach(HighlightKind.allCases) { kind in
                    Button(kind.name) { model.setKind(kind, for: record) }
                        .disabled(kind == record.kind)
                }
            }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
            }
            Divider()
            Button("Delete Highlight", role: .destructive) { model.delete(record) }
        }
    }

    private func startEditing() {
        draft = record.note
        isEditing = true
        isNoteFocused = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        model.setNote(draft, for: record)
    }
}
