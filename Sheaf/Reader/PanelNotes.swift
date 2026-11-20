import SwiftUI

/// A page's note in the Highlights panel, under its page with a note icon.
/// Click it to edit it right there. With no note yet (Add Page Note), it
/// opens empty, ready to type in.
struct PageNoteCard: View {
    let model: ReaderModel
    let page: Int
    let note: PageNote?

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var label: String { model.pageLabel(at: page) }
    private var field: DraftField { .pageNote(page) }
    /// The note's field is showing: it's being edited, or it's a new note.
    private var isTyping: Bool { isEditing || note == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 13)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if isEditing || note == nil {
                    TextField("Write about this page\u{2026}", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2...8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                        .focused($isFocused)
                        .onSubmit(commit)
                        .onExitCommand(perform: cancel)
                        .accessibilityLabel("Note on page \(label)")
                    Text("Return to save \u{00B7} Esc to cancel")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkMuted)
                } else if let note {
                    Button(action: startEditing) {
                        Text(note.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.sheaf(.quiet, in: Rectangle()))
                    .help("Edit this page\u{2019}s note")
                    .accessibilityLabel("Note on page \(label): \(note.text)")
                    .accessibilityHint("Edits the note")
                    .accessibilityAction(named: "Delete note") { model.deletePageNote(note) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        // Gray rather than white with a border, so it reads as hers, not the PDF's.
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isEditing || isHovered ? Theme.control : .clear, lineWidth: 1)
        )
        .animation(Theme.hoverAnimation, value: isHovered)
        .onHover { isHovered = $0 }
        .onChange(of: isFocused) { _, focused in
            if !focused && isTyping { commit() }
        }
        // The reader keeps what's typed as it's typed, and saves it if Sheaf
        // quits or the PDF closes first.
        .onChange(of: draft) {
            if isTyping { model.keepDraft(draft, for: field) }
        }
        .onAppear {
            // An empty note to type in: saving it as it is takes it away.
            if note == nil { model.keepDraft(draft, for: field) }
            startEditingIfAsked()
        }
        .onChange(of: model.pendingPageNoteEdit) { startEditingIfAsked() }
        // Hiding the panel or leaving the PDF keeps what was typed.
        .onDisappear {
            if isTyping { commit() }
        }
        .contextMenu {
            if let note {
                Button("Edit Note", action: startEditing)
                Button("Go to Page \(label)") { model.goToPage(number: page + 1) }
                Button("Copy Text") { Citation.copy(note.text) }
                Divider()
                Button("Delete Note", role: .destructive) { model.deletePageNote(note) }
            }
        }
    }

    private func startEditingIfAsked() {
        guard model.pendingPageNoteEdit == page else { return }
        model.pendingPageNoteEdit = nil
        startEditing()
    }

    private func startEditing() {
        draft = note?.text ?? ""
        isEditing = true
        isFocused = true
        model.keepDraft(draft, for: field)
    }

    private func commit() {
        isEditing = false
        model.saveDraft(field)
    }

    private func cancel() {
        isEditing = false
        model.discardDraft(field)
        draft = note?.text ?? ""
        // An empty note that was never saved goes away.
        if note == nil { model.pageNoteDraftPage = nil }
    }
}

/// "My summary" at the top of the Highlights panel: what the PDF is about,
/// in her own words. It can be folded away; it's saved when she clicks
/// elsewhere, leaves the PDF or quits.
struct SummarySection: View {
    let model: ReaderModel

    @AppStorage("showsSummary") private var isExpanded = true
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.motion) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.inkMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    SectionLabel(title: "My summary")
                    if !isExpanded, let preview {
                        Text(preview)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sheaf(.quiet, in: Rectangle()))
            .help(isExpanded ? "Fold away your summary" : "Show your summary")
            .accessibilityLabel("My summary")
            .accessibilityValue(isExpanded ? "Shown" : "Folded away")
            .accessibilityHint(isExpanded ? "Folds the summary away" : "Shows the summary")

            if isExpanded {
                editor
                    .transition(.opacity)
            }
        }
        .onAppear { draft = model.summary }
        // Undo, or another window, changed it.
        .onChange(of: model.summary) { _, summary in
            if !isFocused { draft = summary }
        }
        // The reader keeps what's typed as it's typed, and saves it if Sheaf
        // quits or the PDF closes first.
        .onChange(of: draft) {
            if isFocused { model.keepDraft(draft, for: .summary) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { model.saveDraft(.summary) }
        }
        .onDisappear { model.saveDraft(.summary) }
    }

    /// The first line, shown beside the title while folded away.
    private var preview: String? {
        let line = model.summary.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }

    /// Grows with the text (an invisible copy of it sets the height), up to
    /// nine lines; past that it scrolls. Return starts a new line, since a
    /// summary can have paragraphs.
    private var editor: some View {
        Text(draft.isEmpty ? " " : draft + " ")
            .font(.system(size: 12.5))
            .lineLimit(9)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
            .opacity(0)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("In your own words: what\u{2019}s this PDF about, and what will you use it for?")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                TextEditor(text: $draft)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .accessibilityLabel("My summary")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
    }
}
