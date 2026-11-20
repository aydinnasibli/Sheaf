import AppKit
import Observation
import PDFKit
import SwiftUI

/// A popover over the page, pointing at a highlight or the top of a page.
/// It follows the page as it scrolls, and closes when that spot scrolls
/// out of sight or she clicks elsewhere.
final class PagePopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var anchor: (() -> CGRect?)?
    private var onClose: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    var isShown: Bool { popover?.isShown ?? false }

    /// Shows `content` pointing at `anchor()`, a rectangle in `view`, on its
    /// `edge` side if there's room. `onClose` runs once it closes, however
    /// that happens.
    func show(
        _ content: some View, in view: NSView, edge: NSRectEdge,
        anchor: @escaping () -> CGRect?, onClose: @escaping () -> Void
    ) {
        close()
        // A popover needs a window on screen to show in (tests have none).
        guard view.window?.isVisible == true, let rect = anchor() else { return }
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host
        popover.delegate = self
        self.popover = popover
        self.anchor = anchor
        self.onClose = onClose
        follow(view)
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
    }

    /// Closes the popover and runs its `onClose` right away (the popover
    /// itself may take a moment to fade out).
    func close() {
        guard let popover else { return }
        finish()
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        // Only the popover on screen: one closed by `close()` is finished already.
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        finish()
    }

    private func finish() {
        let onClose = onClose
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        popover = nil
        anchor = nil
        self.onClose = nil
        onClose?()
    }

    /// Moves along with the page as it scrolls, zooms or turns.
    private func follow(_ view: NSView) {
        let center = NotificationCenter.default
        var sources: [(Notification.Name, AnyObject)] = [(.PDFViewPageChanged, view), (.PDFViewScaleChanged, view)]
        if let clip = (view as? PDFView)?.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            sources.append((NSView.boundsDidChangeNotification, clip))
        }
        observers = sources.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            }
        }
    }

    private func reposition() {
        guard let popover, popover.isShown else { return }
        if let rect = anchor?() {
            popover.positioningRect = rect
        } else {
            popover.close()
        }
    }
}

/// What's typed in a popover's note field, read when the popover closes.
@Observable
final class NoteDraft {
    var text: String
    /// Esc, or the highlight was deleted: nothing to save.
    var isCancelled = false
    /// The answer being typed to a question, or `nil` when she isn't
    /// answering. Typed text is kept when the popover closes, like the note.
    var answer: String?

    init(text: String) {
        self.text = text
    }
}

/// The popover at a highlight clicked on the page: a note, the four colors,
/// the answer for a question, Copy, Copy as Quote and Delete. It looks the
/// highlight up by ID each time, so it never touches one that was just
/// deleted (by Undo, say).
struct HighlightPopoverView: View {
    let model: ReaderModel
    let id: UUID
    @Bindable var draft: NoteDraft
    let dismiss: () -> Void

    @FocusState private var isNoteFocused: Bool
    @FocusState private var isAnswerFocused: Bool

    private var record: HighlightRecord? { model.highlight(id: id) }

    var body: some View {
        let kind = record?.kind
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(HighlightKind.allCases) { option in
                    ColorButton(kind: option, isSelected: kind == option) {
                        if let record { model.setKind(option, for: record) }
                    }
                }
                Spacer(minLength: 8)
                Text(kind?.name ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }

            NoteField(placeholder: "Write a note\u{2026}", text: $draft.text, isFocused: $isNoteFocused) {
                dismiss()
            } cancel: {
                draft.isCancelled = true
                dismiss()
            }

            if let record, record.kind == .question {
                answer(for: record)
            }

            Hairline()

            HStack(spacing: 6) {
                PopoverButton(title: "Copy", systemImage: "doc.on.doc") {
                    if let record { Citation.copy(record.text) }
                    dismiss()
                }
                .help("Copy the highlighted text")
                PopoverButton(title: "Copy as Quote", systemImage: "quote.opening") {
                    if let record { Citation.copy(model.quote(for: record)) }
                    dismiss()
                }
                .help("Copy it in quotes, with the title and page (\u{21E7}\u{2318}C)")
                Spacer(minLength: 8)
                PopoverButton(title: "Delete", systemImage: "trash", isIconOnly: true) {
                    draft.isCancelled = true
                    let record = record
                    dismiss()
                    if let record { model.delete(record) }
                }
                .help("Delete this highlight (\u{2318}Z brings it back)")
            }
        }
        .padding(14)
        .frame(width: 320)
        .task {
            // Once the popover is up, so typing goes straight into the note.
            await Task.yield()
            isNoteFocused = true
        }
    }

    /// A question's answer: "Answer…" while it's open, the answer with a
    /// check once it's answered, or the field she's typing it in.
    @ViewBuilder
    private func answer(for record: HighlightRecord) -> some View {
        if draft.answer != nil {
            NoteField(
                placeholder: "Write the answer\u{2026}",
                text: Binding(get: { draft.answer ?? "" }, set: { draft.answer = $0 }),
                isFocused: $isAnswerFocused,
                hint: CardTextField.answerHint,
                accessibilityLabel: "Answer"
            ) {
                // Return marks it answered, even with nothing written.
                model.setAnswer(draft.answer ?? "", isAnswered: true, for: record)
                draft.answer = nil
                dismiss()
            } cancel: {
                draft.answer = nil
                isNoteFocused = true
            }
        } else if record.isAnswered {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AnswerLine(answer: record.answer, tint: record.kind.chipText, font: .system(size: 13))
                PopoverButton(title: "Edit", systemImage: "pencil", isIconOnly: true) { startAnswering(record) }
                    .help("Edit the answer")
                PopoverButton(title: "Mark as Unanswered", systemImage: "arrow.uturn.backward", isIconOnly: true) {
                    model.setAnswer(record.answer, isAnswered: false, for: record)
                }
                .help("Mark as unanswered, so it counts as an open question again")
            }
        } else {
            PopoverButton(title: "Answer\u{2026}", systemImage: "checkmark.circle") { startAnswering(record) }
                .help("Write what you found out, and the question no longer counts as open")
        }
    }

    private func startAnswering(_ record: HighlightRecord) {
        draft.answer = record.answer
        isAnswerFocused = true
    }
}

/// The popover for a page's note.
struct PageNotePopoverView: View {
    let model: ReaderModel
    let pageIndex: Int
    @Bindable var draft: NoteDraft
    let dismiss: () -> Void

    @FocusState private var isNoteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Note on page \(model.pageLabel(at: pageIndex))", systemImage: "note.text")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)

            NoteField(placeholder: "Write about this page\u{2026}", text: $draft.text, isFocused: $isNoteFocused, minLines: 3) {
                dismiss()
            } cancel: {
                draft.isCancelled = true
                dismiss()
            }

            if let note = model.pageNote(onPage: pageIndex) {
                HStack {
                    Spacer()
                    PopoverButton(title: "Delete Note", systemImage: "trash") {
                        draft.isCancelled = true
                        model.deletePageNote(note)
                        dismiss()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .task {
            await Task.yield()
            isNoteFocused = true
        }
    }
}

/// A note field: Return saves, Esc cancels, as on the highlight cards.
struct NoteField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var minLines = 2
    var hint = "Return to save \u{00B7} Esc to cancel"
    var accessibilityLabel = "Note"
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineLimit(minLines...8)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                .focused(isFocused)
                .onSubmit(save)
                .onExitCommand(perform: cancel)
                .accessibilityLabel(accessibilityLabel)
            Text(hint)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.inkMuted)
        }
    }
}

/// One of the four colors in the highlight popover.
private struct ColorButton: View {
    let kind: HighlightKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(kind.swatch)
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.12), lineWidth: 1))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.sheaf(cornerRadius: 8))
        .help(isSelected ? kind.name : "Make it \(kind.name) (\(kind.purpose.lowercased()))")
        .accessibilityLabel(kind.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small bordered button in a popover.
private struct PopoverButton: View {
    let title: String
    let systemImage: String
    var isIconOnly = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isIconOnly {
                    Image(systemName: systemImage)
                        .frame(width: 28)
                } else {
                    Label(title, systemImage: systemImage)
                        .padding(.horizontal, 9)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.control, lineWidth: 1))
        }
        .buttonStyle(.sheaf(cornerRadius: 7))
        .accessibilityLabel(title)
    }
}
