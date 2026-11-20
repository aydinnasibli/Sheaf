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

            SummarySection(model: model)

            HighlightFilterChips(model: model)

            if !model.bookmarks.isEmpty {
                BookmarkChips(model: model)
            }

            if let block = model.fileWriteBlock {
                Label(block.explanation, systemImage: "lock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.highlights.isEmpty && model.pageNotes.isEmpty && model.pageNoteDraftPage == nil {
                emptyState
            } else {
                list
            }

            Spacer(minLength: 0)

            SecondaryButton(
                title: "Export as Markdown",
                systemImage: "square.and.arrow.down",
                fillsWidth: true,
                action: model.exportMarkdown
            )
            .help("Save your summary, highlights and notes as a Markdown file")
            .disabled(!model.hasAnythingToExport)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(Theme.background)
        // While the panel is hidden (focus mode, a narrow window, search
        // results), notes open in a popover on the page instead.
        .onAppear { model.isHighlightsPanelVisible = true }
        .onDisappear { model.isHighlightsPanelVisible = false }
    }

    /// Pages with their note and highlights, as one list so any card can be
    /// scrolled to.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        switch row {
                        case .page(let page):
                            SectionLabel(title: "Page \(model.pageLabel(at: page))")
                                .padding(.top, 6)
                        case .pageNote(let page, let note):
                            PageNoteCard(model: model, page: page, note: note)
                        case .highlight(let record):
                            HighlightCard(record: record, model: model, isSelected: model.selectedHighlightID == record.id)
                        }
                    }
                }
            }
            // A highlight clicked on the page, or just made, comes into view.
            .onChange(of: model.selectedHighlightID) { _, id in
                guard let id else { return }
                withAnimation(Theme.motion) { proxy.scrollTo(PanelRow.ID.highlight(id)) }
            }
            .onChange(of: model.pendingNoteEditID) { _, id in
                if let id { proxy.scrollTo(PanelRow.ID.highlight(id)) }
            }
            .onChange(of: model.pendingPageNoteEdit) { _, page in
                if let page { proxy.scrollTo(PanelRow.ID.pageNote(page)) }
            }
        }
    }

    private var rows: [PanelRow] {
        model.panelGroups.flatMap { group in
            var rows: [PanelRow] = [.page(group.page)]
            if group.note != nil || group.hasDraftNote {
                rows.append(.pageNote(group.page, group.note))
            }
            rows += group.items.map(PanelRow.highlight)
            return rows
        }
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
}

/// The bookmarked pages; click one to go there.
struct BookmarkChips: View {
    let model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Bookmarks")
            FlowLayout(spacing: 6) {
                ForEach(model.bookmarks, id: \.self) { index in
                    let isHere = model.visiblePageIndices.contains(index)
                    let label = model.pageLabel(at: index)
                    Button { model.goToBookmark(index) } label: {
                        Label("Page \(label)", systemImage: "bookmark.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize()
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(Theme.field, in: Capsule())
                            .overlay(Capsule().strokeBorder(isHere ? Theme.accent : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.sheaf(.overlay, in: Capsule()))
                    .help("Go to page \(label)")
                    .accessibilityLabel("Bookmark, page \(label)")
                    .contextMenu {
                        Button("Remove Bookmark") { model.toggleBookmark(page: index) }
                    }
                }
            }
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
                        .animation(Theme.hoverAnimation, value: isOn)
                }
                .buttonStyle(.sheaf(.overlay, in: Capsule()))
                .help(isOn ? "Show all colors" : "Show only \(kind.name)")
                .accessibilityLabel("\(kind.name), \(model.count(of: kind))")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

/// A highlight in the panel. Click the text to go to it; click the note
/// (or "Add note") to type a note right on the card. Drag the text out of
/// Sheaf to drop it as a quote.
struct HighlightCard: View {
    let record: HighlightRecord
    let model: ReaderModel
    /// Clicked on the page or just made: outlined.
    var isSelected = false

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovered = false
    /// Typing the answer to a question.
    @State private var isAnswering = false
    @State private var answerDraft = ""
    @FocusState private var isNoteFocused: Bool
    @FocusState private var isAddNoteFocused: Bool
    @FocusState private var isAnswerFocused: Bool
    @FocusState private var isAnswerButtonFocused: Bool

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
                }
                .buttonStyle(.sheaf(.quiet, in: Rectangle()))
                .help("Go to this highlight. Drag it out of Sheaf to drop it as a quote.")
                .accessibilityLabel("\(record.kind.name): \(record.text)")
                .accessibilityHint("Goes to this highlight")
                .accessibilityAction(named: record.note.isEmpty ? "Add note" : "Edit note", startEditing)
                .accessibilityAction(named: "Copy as quote") { Citation.copy(model.quote(for: record)) }
                .accessibilityActions { answerActions }
                .onDrag { Citation.dragItem(model.quote(for: record)) }

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
                    }
                    .buttonStyle(.sheaf(.quiet, in: Rectangle()))
                    .help("Edit note")
                }

                answer
                quietRow
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(border, lineWidth: isSelected ? 1.5 : 1)
        )
        .animation(Theme.hoverAnimation, value: isHovered)
        .animation(Theme.hoverAnimation, value: isSelected)
        .onHover { isHovered = $0 }
        .onChange(of: isNoteFocused) { _, focused in
            if !focused && isEditing { commit() }
        }
        .onChange(of: isAnswerFocused) { _, focused in
            if !focused && isAnswering { commitAnswer(isReturn: false) }
        }
        // The note shortcut asks for this card's note.
        .onAppear(perform: startEditingIfAsked)
        .onChange(of: model.pendingNoteEditID) { startEditingIfAsked() }
        .contextMenu {
            Button(record.note.isEmpty ? "Add Note" : "Edit Note", action: startEditing)
            if record.kind == .question {
                Button(record.isAnswered ? "Edit Answer\u{2026}" : "Answer\u{2026}", action: startAnswering)
                Button(record.isAnswered ? "Mark as Unanswered" : "Mark as Answered") {
                    model.setAnswer(record.answer, isAnswered: !record.isAnswered, for: record)
                }
            }
            Menu("Change Color") {
                ForEach(HighlightKind.allCases) { kind in
                    Button(kind.name) { model.setKind(kind, for: record) }
                        .disabled(kind == record.kind)
                }
            }
            Button("Copy Text") { Citation.copy(record.text) }
            Button("Copy as Quote") { Citation.copy(model.quote(for: record)) }
            Divider()
            Button("Delete Highlight", role: .destructive) { model.delete(record) }
        }
    }

    private var border: Color {
        if isSelected { return Theme.accent }
        return isEditing || isAnswering || isHovered ? Theme.control : Theme.border
    }

    /// A question's answer with a check, or the field she's typing it in.
    @ViewBuilder
    private var answer: some View {
        if isAnswering {
            CardTextField(
                placeholder: "Write the answer\u{2026}", text: $answerDraft, isFocused: $isAnswerFocused,
                hint: CardTextField.answerHint, accessibilityLabel: "Answer"
            ) {
                commitAnswer(isReturn: true)
            } cancel: {
                isAnswering = false
            }
        } else if record.isAnsweredQuestion {
            Button(action: startAnswering) {
                AnswerLine(answer: record.answer, tint: record.kind.chipText)
            }
            .buttonStyle(.sheaf(.quiet, in: Rectangle()))
            .help("Edit the answer")
        }
    }

    /// "Add note" and, for an open question, "Answer…". The row always
    /// takes its space, so hovering a card doesn't push the cards below it
    /// down. It shows under the pointer, on the selected card, and when the
    /// keyboard reaches it.
    @ViewBuilder
    private var quietRow: some View {
        let addsNote = !isEditing && record.note.isEmpty
        let answers = !isAnswering && record.isOpenQuestion
        if addsNote || answers {
            HStack(spacing: 14) {
                if addsNote {
                    Button(action: startEditing) {
                        Label("Add note", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.sheaf(.quiet, in: Rectangle()))
                    .focused($isAddNoteFocused)
                    .help("Add a note (\u{2325}\u{2318}N for the highlight just made)")
                    .accessibilityLabel("Add note")
                }
                if answers {
                    Button(action: startAnswering) {
                        Label("Answer\u{2026}", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    .buttonStyle(.sheaf(.quiet, in: Rectangle()))
                    .focused($isAnswerButtonFocused)
                    .help("Write what you found out, and the question no longer counts as open")
                    .accessibilityLabel("Answer")
                }
            }
            .opacity(isHovered || isSelected || isAddNoteFocused || isAnswerButtonFocused ? 1 : 0)
        }
    }

    @ViewBuilder
    private var answerActions: some View {
        if record.kind == .question {
            Button(record.isAnswered ? "Edit answer" : "Answer", action: startAnswering)
            if record.isAnswered {
                Button("Mark as unanswered") { model.setAnswer(record.answer, isAnswered: false, for: record) }
            }
        }
    }

    private func startAnswering() {
        answerDraft = record.answer
        isAnswering = true
        isAnswerFocused = true
    }

    /// Return marks the question answered, even with nothing written;
    /// clicking away from an empty answer leaves it open.
    private func commitAnswer(isReturn: Bool) {
        guard isAnswering else { return }
        isAnswering = false
        let text = answerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReturn || !text.isEmpty || record.isAnswered else { return }
        model.setAnswer(text, isAnswered: true, for: record)
    }

    private func startEditingIfAsked() {
        guard model.pendingNoteEditID == record.id else { return }
        model.pendingNoteEditID = nil
        startEditing()
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

/// One row of the Highlights panel's list.
private enum PanelRow: Identifiable {
    case page(Int)
    case pageNote(Int, PageNote?)
    case highlight(HighlightRecord)

    enum ID: Hashable {
        case page(Int)
        case pageNote(Int)
        case highlight(UUID)
    }

    var id: ID {
        switch self {
        case .page(let page): .page(page)
        case .pageNote(let page, _): .pageNote(page)
        case .highlight(let record): .highlight(record.id)
        }
    }
}
