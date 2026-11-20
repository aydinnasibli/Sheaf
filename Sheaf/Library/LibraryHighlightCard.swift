import SwiftData
import SwiftUI

/// A highlight on the library's Highlights and Notes pages. Click the text
/// to open the PDF there; click the note or answer to edit it on the card.
/// Under the pointer (or when the keyboard reaches it) the card shows Add
/// note, Answer…, the colors and Delete; the context menu has them too.
/// Changes go through `Workspace`, so they reach an open PDF's reader, or
/// the file the next time it opens, and ⌘Z takes them back.
struct LibraryHighlightCard: View {
    let record: HighlightRecord
    /// The PDF's title beside the page; left out under a PDF's heading.
    var showsTitle = true
    let onOpen: () -> Void

    @Environment(Workspace.self) private var workspace
    @Environment(\.undoManager) private var undoManager

    private enum Editor { case note, answer }
    private enum Control: Hashable { case note, answer, color, delete }

    @State private var editor: Editor?
    @State private var draft = ""
    @State private var isHovered = false
    @FocusState private var isFieldFocused: Bool
    @FocusState private var focusedControl: Control?

    private var title: String { record.entry?.title ?? "PDF" }
    private var showsControls: Bool { isHovered || focusedControl != nil }

    var body: some View {
        // Deleted a moment ago: the list drops the card once it updates.
        if record.modelContext != nil && !record.isDeleted {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Button(action: onOpen) {
                Text(record.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.sheaf(.quiet, in: Rectangle()))
            .help("Open \u{201C}\(title)\u{201D} at page \(record.displayPage). Drag it out of Sheaf to drop it as a quote.")
            .accessibilityLabel(HighlightsPage.spokenLabel(for: record))
            .accessibilityHint("Opens the PDF at this highlight")
            .accessibilityActions { accessibilityActions }
            // Dropped into an essay, it arrives as a quote with its source.
            .onDrag { Citation.dragItem(record.quote) }

            if editor == .note {
                CardTextField(
                    placeholder: "Write a note\u{2026}", text: $draft, isFocused: $isFieldFocused, background: Theme.raised
                ) {
                    commit()
                } cancel: {
                    editor = nil
                }
            } else if !record.note.isEmpty {
                Button { startEditing(.note) } label: {
                    Text(record.note)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.sheaf(.quiet, in: Rectangle()))
                .help("Edit note")
            }

            if editor == .answer {
                CardTextField(
                    placeholder: "Write the answer\u{2026}", text: $draft, isFocused: $isFieldFocused,
                    hint: CardTextField.answerHint, background: Theme.raised, accessibilityLabel: "Answer"
                ) {
                    commit(isReturn: true)
                } cancel: {
                    editor = nil
                }
            } else if record.isAnsweredQuestion {
                Button { startEditing(.answer) } label: {
                    AnswerLine(answer: record.answer, tint: record.kind.chipText, font: .system(size: 13))
                }
                .buttonStyle(.sheaf(.quiet, in: Rectangle()))
                .help("Edit the answer")
            }

            Text(showsTitle ? "\(title) \u{00B7} p. \(record.displayPage)" : "p. \(record.displayPage)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(record.kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            // The hover tint the whole card used to have as one button.
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered && editor == nil ? Theme.hoverTint : .clear)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .animation(Theme.hoverAnimation, value: isHovered)
        .onHover { isHovered = $0 }
        .onChange(of: isFieldFocused) { _, focused in
            if !focused && editor != nil { commit() }
        }
        // Leaving the page while typing keeps what was typed, as do
        // quitting and exporting.
        .onDisappear { if editor != nil { commit() } }
        .onReceive(NotificationCenter.default.publisher(for: .sheafFlushSaves)) { _ in
            if editor != nil { commit() }
        }
        .contextMenu { menu }
    }

    // MARK: Parts

    /// The color's name and, for an answered question, "Answered"; then the
    /// date, or the card's controls while they show.
    private var header: some View {
        HStack(spacing: 8) {
            Text(record.isAnsweredQuestion ? "\(record.kind.name.uppercased()) \u{00B7} ANSWERED" : record.kind.name.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(record.kind.chipText)
                .lineLimit(1)
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Text(record.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
                    .opacity(showsControls ? 0 : 1)
                controls
                    .opacity(showsControls ? 1 : 0)
            }
        }
        .frame(minHeight: 24)
        .animation(Theme.hoverAnimation, value: showsControls)
    }

    /// Add note, Answer…, the colors and Delete. Quiet until the pointer or
    /// the keyboard reaches the card, so a long list stays calm to read.
    private var controls: some View {
        HStack(spacing: 2) {
            if record.isOpenQuestion && editor != .answer {
                Button { startEditing(.answer) } label: {
                    Label("Answer\u{2026}", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                }
                .buttonStyle(.sheaf(.overlay, cornerRadius: 6))
                .focused($focusedControl, equals: .answer)
                .help("Write what you found out, and the question no longer counts as open")
                .accessibilityLabel("Answer")
            }
            if record.note.isEmpty && editor != .note {
                iconButton("Add Note", systemImage: "square.and.pencil", control: .note) { startEditing(.note) }
            }
            Menu {
                colorChoices
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 26, height: 24)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.sheaf(.overlay, cornerRadius: 6))
            .fixedSize()
            .focused($focusedControl, equals: .color)
            .help("Change the color")
            .accessibilityLabel("Change Color")
            iconButton("Delete Highlight", systemImage: "trash", control: .delete, action: delete)
                .help("Delete this highlight (\u{2318}Z brings it back)")
        }
    }

    private func iconButton(_ label: String, systemImage: String, control: Control, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.sheaf(.overlay, cornerRadius: 6))
        .focused($focusedControl, equals: control)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The four colors, the highlight's checked, as in the Highlights panel.
    @ViewBuilder
    private var colorChoices: some View {
        ForEach(HighlightKind.allCases) { kind in
            Toggle(kind.menuTitle, isOn: Binding(
                get: { record.kind == kind },
                set: { if $0 { workspace.setKind(kind, forHighlight: record.id, undoManager: undoManager) } }
            ))
        }
    }

    /// The same items, in the same order, as a highlight's menu in the
    /// Highlights panel.
    @ViewBuilder
    private var menu: some View {
        Button("Show in PDF", action: onOpen)
        Button("Copy Text") { Citation.copy(record.text) }
        Button("Copy as Quote") { Citation.copy(record.quote) }
        Divider()
        Button(record.note.isEmpty ? "Add Note" : "Edit Note") { startEditing(.note) }
        if record.kind == .question {
            Button(record.isAnswered ? "Edit Answer\u{2026}" : "Answer\u{2026}") { startEditing(.answer) }
            Button(record.isAnswered ? "Mark as Unanswered" : "Mark as Answered") {
                setAnswered(!record.isAnswered)
            }
        }
        Menu("Change Color") { colorChoices }
        Divider()
        Button("Delete Highlight", role: .destructive, action: delete)
    }

    /// The menu's items for VoiceOver, named as in the menu.
    @ViewBuilder
    private var accessibilityActions: some View {
        Button("Copy Text") { Citation.copy(record.text) }
        Button("Copy as Quote") { Citation.copy(record.quote) }
        Button(record.note.isEmpty ? "Add Note" : "Edit Note") { startEditing(.note) }
        if record.kind == .question {
            Button(record.isAnswered ? "Edit Answer" : "Answer") { startEditing(.answer) }
            Button(record.isAnswered ? "Mark as Unanswered" : "Mark as Answered") { setAnswered(!record.isAnswered) }
        }
        ForEach(HighlightKind.allCases.filter { $0 != record.kind }) { kind in
            Button("Change Color to \(kind.menuTitle)") { workspace.setKind(kind, forHighlight: record.id, undoManager: undoManager) }
        }
        Button("Delete Highlight", action: delete)
    }

    // MARK: Editing

    private func startEditing(_ editor: Editor) {
        draft = editor == .note ? record.note : record.answer
        self.editor = editor
        isFieldFocused = true
    }

    /// Saves what was typed. Return on an answer marks the question
    /// answered, even with nothing written; clicking away from an empty
    /// answer leaves it open.
    private func commit(isReturn: Bool = false) {
        guard let editor else { return }
        self.editor = nil
        // Deleted meanwhile (by Undo, say): there's nothing to save it on.
        guard record.modelContext != nil, !record.isDeleted else { return }
        switch editor {
        case .note:
            workspace.setNote(draft, forHighlight: record.id, undoManager: undoManager)
        case .answer:
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isReturn || !text.isEmpty || record.isAnswered else { return }
            workspace.setAnswer(text, isAnswered: true, forHighlight: record.id, undoManager: undoManager)
        }
    }

    private func setAnswered(_ isAnswered: Bool) {
        workspace.setAnswer(record.answer, isAnswered: isAnswered, forHighlight: record.id, undoManager: undoManager)
    }

    private func delete() {
        editor = nil
        workspace.deleteHighlight(id: record.id, undoManager: undoManager)
    }
}
