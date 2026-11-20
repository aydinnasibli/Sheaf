import SwiftData
import SwiftUI

/// Flashcards from her highlights, the library's Review section. First she
/// chooses colors and PDFs, then goes through the cards one at a time, and
/// gets a short summary at the end. The review in progress is kept by the
/// workspace, so opening a PDF from a card doesn't lose it.
struct ReviewPage: View {
    let highlights: [HighlightRecord]
    let entries: [LibraryEntry]
    let collections: [PDFCollection]

    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if let deck = workspace.review {
                if deck.isFinished {
                    ReviewSummary(deck: deck)
                } else {
                    ReviewSession(deck: deck)
                }
            } else {
                ReviewSetup(highlights: highlights, entries: entries, collections: collections)
            }
        }
        .libraryPage()
    }
}

/// "Review" in the page's display type, with a detail like "4 of 20".
private struct ReviewTitle: View {
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Review")
                .font(Theme.display(32))
                .tracking(-0.9)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(Theme.inkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private func cardCount(_ count: Int) -> String {
    count == 1 ? "1 card" : "\(count) cards"
}

/// Opens the PDF at a card's highlight.
@MainActor
private func showInPDF(_ card: ReviewCard, library: LibraryStore) {
    guard let id = card.entryID, let entry = library.entry(id: id) else { return }
    WindowRouter.shared.open(entry, at: library.highlight(id: card.id))
}

// MARK: - Choosing cards

private struct ReviewSetup: View {
    let highlights: [HighlightRecord]
    let entries: [LibraryEntry]
    let collections: [PDFCollection]

    @Environment(Workspace.self) private var workspace
    /// The colors to review, remembered between reviews. "3" is Definition.
    @AppStorage("reviewKinds") private var kindsValue = String(HighlightKind.definition.rawValue)
    @State private var source = ReviewSource.all

    private var kinds: Set<HighlightKind> {
        Set(kindsValue.split(separator: ",").compactMap { Int($0).flatMap(HighlightKind.init(rawValue:)) })
    }

    /// The chosen PDFs, or all of them if the chosen collection or PDF is gone.
    private var validSource: ReviewSource {
        switch source {
        case .all: .all
        case .collection(let id): collections.contains { $0.id == id } ? source : .all
        case .entry(let id): entries.contains { $0.id == id } ? source : .all
        }
    }

    private var sourceTitle: String {
        switch validSource {
        case .all: "All PDFs"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "All PDFs"
        case .entry(let id): entries.first { $0.id == id }?.title ?? "All PDFs"
        }
    }

    var body: some View {
        let kinds = kinds
        let cards = ReviewDeck.cards(from: highlights, kinds: kinds, source: validSource)
        VStack(alignment: .leading, spacing: 16) {
            ReviewTitle(detail: cardCount(cards.count))
            Text("Flashcards from your highlights. Each card shows your note, or the PDF and page, and hides what you highlighted. Remember it, then check.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
                .frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 6) {
                ForEach(HighlightKind.allCases) { kind in
                    FilterChip(title: kind.name, dot: kind.vivid, isSelected: kinds.contains(kind)) {
                        toggle(kind, in: kinds)
                    }
                    .help("\(kind.purpose). Click to \(kinds.contains(kind) ? "leave out" : "include") these highlights.")
                }
                sourceMenu(kinds: kinds)
            }

            if cards.isEmpty {
                emptyMessage(kinds: kinds)
            } else {
                start(cards, kinds: kinds)
            }
        }
    }

    private func toggle(_ kind: HighlightKind, in kinds: Set<HighlightKind>) {
        var kinds = kinds
        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
        kindsValue = kinds.map(\.rawValue).sorted().map(String.init).joined(separator: ",")
    }

    private func start(_ cards: [ReviewCard], kinds: Set<HighlightKind>) -> some View {
        VStack(spacing: 20) {
            DeckPicture(kinds: Set(cards.map(\.kind)))
            PrimaryButton(title: "Start Review", systemImage: "play.fill") {
                workspace.review = ReviewDeck(cards: cards, kinds: kinds, source: validSource)
            }
            .keyboardShortcut(.defaultAction)
            .help("Go through \(cardCount(cards.count)), shuffled (Return)")
            Text("Space shows the answer \u{00B7} 1 Again \u{00B7} 2 Got it")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    @ViewBuilder
    private func emptyMessage(kinds: Set<HighlightKind>) -> some View {
        let chosen = HighlightKind.allCases.filter(kinds.contains)
        let colors = chosen.map(\.name).formatted(.list(type: .or))
        if kinds.isEmpty {
            EmptyMessage(
                systemImage: "highlighter",
                title: "Choose a color",
                message: "Pick one or more highlight colors to make cards from."
            )
        } else if validSource != .all, !ReviewDeck.cards(from: highlights, kinds: kinds, source: .all).isEmpty {
            EmptyMessage(
                systemImage: "rectangle.on.rectangle.angled",
                title: "No cards here",
                message: "\u{201C}\(sourceTitle)\u{201D} has no \(colors) highlights.",
                actionTitle: "Review All PDFs"
            ) { source = .all }
        } else {
            let keys = chosen.map { String($0.rawValue) }.formatted(.list(type: .and))
            EmptyMessage(
                systemImage: "rectangle.on.rectangle.angled",
                title: "No \(colors) highlights yet",
                message: "Mark text with the \(colors) highlighter (\(chosen.count == 1 ? "key" : "keys") \(keys)) while reading, and it becomes a card here. A note on a highlight becomes its question."
            )
        }
    }

    private func sourceMenu(kinds: Set<HighlightKind>) -> some View {
        Menu {
            Toggle("All PDFs", isOn: isChosen(.all))
            if !collections.isEmpty {
                Section("Collections") {
                    ForEach(collections) { collection in
                        Toggle(collection.name, isOn: isChosen(.collection(collection.id)))
                    }
                }
            }
            // Only PDFs with highlights of the chosen colors.
            let pdfs = entries
                .filter { entry in entry.highlights.contains { kinds.contains($0.kind) } }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !pdfs.isEmpty {
                Section("PDFs") {
                    ForEach(pdfs) { entry in
                        Toggle(entry.title, isOn: isChosen(.entry(entry.id)))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(sourceTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 13)
            .frame(maxWidth: 280)
            .frame(height: 30)
            .overlay(Capsule().strokeBorder(Theme.control, lineWidth: 1))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.sheaf(in: Capsule()))
        .fixedSize()
        .help("Choose which PDFs to review: all of them, a collection or one PDF")
        .accessibilityLabel("Review from")
        .accessibilityValue(sourceTitle)
    }

    private func isChosen(_ option: ReviewSource) -> Binding<Bool> {
        Binding(get: { validSource == option }, set: { if $0 { source = option } })
    }
}

/// A small fanned stack of cards in the colors being reviewed.
private struct DeckPicture: View {
    let kinds: Set<HighlightKind>

    var body: some View {
        let colors = HighlightKind.allCases.filter(kinds.contains)
        ZStack {
            ForEach(0..<3, id: \.self) { layer in
                let kind = colors.isEmpty ? HighlightKind.definition : colors[layer % colors.count]
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.raised)
                    .overlay(alignment: .top) { Rectangle().fill(kind.swatch).frame(height: 7) }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.control, lineWidth: 1))
                    .frame(width: 150, height: 100)
                    .rotationEffect(.degrees([-7, 4, 0][layer]))
                    .offset(x: [-10, 10, 0][layer], y: [4, 2, -4][layer])
                    .shadow(color: Theme.cardShadow, radius: 6, y: 2)
            }
        }
        .frame(width: 190, height: 130)
        .accessibilityHidden(true)
    }
}

// MARK: - Going through the cards

private struct ReviewSession: View {
    let deck: ReviewDeck

    @Environment(Workspace.self) private var workspace
    @Environment(LibraryStore.self) private var library
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                ReviewTitle(detail: "\(deck.position) of \(deck.cards.count)")
                    .accessibilityLabel("Review, card \(deck.position) of \(deck.cards.count)")
                Spacer()
                SecondaryButton(title: "End Review") { workspace.review = nil }
                    .help("Stop and choose other cards")
            }
            ReviewProgressBar(value: deck.progress)
                .padding(.top, 14)

            if let card = deck.current {
                ViewThatFits(in: .vertical) {
                    content(for: card)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        content(for: card)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) { reveal() }
        .onKeyPress(.return) { reveal() }
        .onKeyPress("1") { answer(gotIt: false) }
        .onKeyPress("2") { answer(gotIt: true) }
        .onAppear { isFocused = true }
    }

    private func content(for card: ReviewCard) -> some View {
        VStack(spacing: 22) {
            ZStack {
                FlashCard(card: card, isRevealed: deck.isRevealed) { _ = reveal() }
                    .id(card.id)
                    .transition(.opacity)
            }
            controls(for: card)
        }
        .padding(.top, 24)
    }

    @ViewBuilder
    private func controls(for card: ReviewCard) -> some View {
        VStack(spacing: 12) {
            if deck.isRevealed {
                HStack(spacing: 10) {
                    SecondaryButton(title: "Again", systemImage: "arrow.counterclockwise") { _ = answer(gotIt: false) }
                        .help("Didn\u{2019}t remember it: see it again in a few cards (1)")
                    PrimaryButton(title: "Got it", systemImage: "checkmark") { _ = answer(gotIt: true) }
                        .help("Remembered it: on to the next card (2)")
                }
                HStack(spacing: 14) {
                    Text("1 Again \u{00B7} 2 Got it")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkMuted)
                        .accessibilityHidden(true)
                    if card.entryID != nil {
                        Button { showInPDF(card, library: library) } label: {
                            Label("Show in PDF", systemImage: "arrow.up.forward")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.inkSecondary)
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                        }
                        .buttonStyle(.sheaf(cornerRadius: 6))
                        .help("Open \u{201C}\(card.title)\u{201D} at this highlight. The review waits here.")
                    }
                }
            } else {
                PrimaryButton(title: "Show Answer") { _ = reveal() }
                    .help("Show what you highlighted (Space)")
                Text("Space shows the answer")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .accessibilityHidden(true)
            }
        }
    }

    private func reveal() -> KeyPress.Result {
        guard let card = deck.current, !deck.isRevealed else { return .ignored }
        withAnimation(Theme.motion) { deck.reveal() }
        AccessibilityNotification.Announcement(card.text).post()
        return .handled
    }

    private func answer(gotIt: Bool) -> KeyPress.Result {
        guard deck.isRevealed else { return .ignored }
        withAnimation(Theme.motion) {
            if gotIt { deck.gotIt() } else { deck.again() }
        }
        return .handled
    }
}

/// A thin bar showing how many cards are done.
private struct ReviewProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Theme.field)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, proxy.size.width * value))
                }
        }
        .frame(height: 4)
        .animation(Theme.motion, value: value)
        .accessibilityHidden(true)
    }
}

/// One card: the cue on the front, the highlighted text hidden until she
/// asks for it, and the highlight's color along the top.
private struct FlashCard: View {
    let card: ReviewCard
    let isRevealed: Bool
    let reveal: () -> Void

    private var page: String { card.page }

    var body: some View {
        Button(action: reveal) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 8) {
                    Capsule().fill(card.kind.swatch).frame(width: 22, height: 10)
                    Text(card.kind.name.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 12)
                    if !card.note.isEmpty {
                        Text("\(card.title) \u{00B7} p. \(page)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.inkMuted)
                            .lineLimit(1)
                    }
                }
                cue
                answer
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 36)
            .frame(minHeight: 300, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.raised)
                    .overlay(alignment: .top) { Rectangle().fill(card.kind.swatch).frame(height: 6) }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.control, lineWidth: 1))
                    .shadow(color: Theme.cardShadow, radius: 22, y: 8)
            }
        }
        .buttonStyle(.sheaf(.overlay, cornerRadius: 18))
        .disabled(isRevealed)
        .frame(maxWidth: 640)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(isRevealed ? "" : "Shows what you highlighted")
    }

    @ViewBuilder
    private var cue: some View {
        if card.note.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Page \(page)")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(card.note)
                .font(.system(size: 24, weight: .medium))
                .lineSpacing(3)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var answer: some View {
        if isRevealed {
            Text(highlightedText)
                .font(.system(size: 21))
                .lineSpacing(7)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HiddenText(kind: card.kind, length: card.text.count)
                Text(card.note.isEmpty ? "What did you highlight here? Click or press Space to see." : "Click or press Space to see what you highlighted.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
            }
            .transition(.opacity)
        }
    }

    /// The answer with the highlighter behind each line, as on the page.
    private var highlightedText: AttributedString {
        var text = AttributedString(card.text)
        text.backgroundColor = card.kind.chipBackground
        return text
    }

    private var spokenLabel: String {
        var label = "\(card.kind.name) card. "
        label += card.note.isEmpty ? "From \(card.title), page \(page). " : "\(card.note). From \(card.title), page \(page). "
        label += isRevealed ? "Answer: \(card.text)" : "Answer hidden."
        return label
    }
}

/// Stands in for the hidden answer: highlighter strokes about as long as
/// the text, so the length is a small hint.
private struct HiddenText: View {
    let kind: HighlightKind
    let length: Int

    /// About how many characters fit on a line of the card.
    private static let lineLength = 52.0

    var body: some View {
        let lines = min(4, max(1, Int((Double(length) / Self.lineLength).rounded(.up))))
        let last = lines == 1 ? min(1, max(0.2, Double(length) / Self.lineLength)) : 0.55
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<lines, id: \.self) { line in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(kind.chipBackground)
                        .frame(width: proxy.size.width * (line == lines - 1 ? last : 1), height: 22)
                }
            }
        }
        .frame(height: CGFloat(lines) * 22 + CGFloat(lines - 1) * 10)
        .accessibilityHidden(true)
    }
}

// MARK: - The end

private struct ReviewSummary: View {
    let deck: ReviewDeck

    @Environment(Workspace.self) private var workspace
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReviewTitle(detail: cardCount(deck.cards.count))
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.inkMuted)
                        .accessibilityHidden(true)
                    Text(deck.missed.isEmpty ? "All remembered" : "Review done")
                        .font(Theme.display(26))
                        .foregroundStyle(Theme.ink)
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .fixedSize(horizontal: false, vertical: true)
                    buttons
                        .padding(.top, 6)
                    if !deck.missed.isEmpty {
                        missedCards
                            .padding(.top, 22)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                .padding(.bottom, 32)
            }
        }
    }

    private var summary: String {
        let total = deck.cards.count
        let missed = deck.missed.count
        if missed == 0 {
            return total == 1 ? "You knew it on the first try." : "You went through \(total) cards and knew every one on the first try."
        }
        return "You went through \(cardCount(total)): \(total - missed) on the first try, \(missed) after another look."
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            if deck.missed.isEmpty {
                PrimaryButton(title: "Start Over", systemImage: "arrow.counterclockwise") {
                    workspace.review = deck.restarted(onlyMissed: false)
                }
                .keyboardShortcut(.defaultAction)
                .help("Go through the same cards again, shuffled (Return)")
            } else {
                PrimaryButton(title: deck.missed.count == 1 ? "Review That One Again" : "Review These \(deck.missed.count) Again") {
                    workspace.review = deck.restarted(onlyMissed: true)
                }
                .keyboardShortcut(.defaultAction)
                .help("Go through only the cards that needed another look (Return)")
                SecondaryButton(title: "Start Over") {
                    workspace.review = deck.restarted(onlyMissed: false)
                }
                .help("Go through every card again, shuffled")
            }
            SecondaryButton(title: "Done") { workspace.review = nil }
                .help("Choose other cards")
        }
    }

    private var missedCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Worth another look")
            ForEach(deck.missed) { card in
                Button { showInPDF(card, library: library) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.kind.name.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(card.kind.chipText)
                        Text(card.text)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(4)
                        if !card.note.isEmpty {
                            Text(card.note)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(2)
                        }
                        Text("\(card.title) \u{00B7} p. \(card.page)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(card.kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.sheaf(.overlay, cornerRadius: 12))
                .help("Open \u{201C}\(card.title)\u{201D} at this highlight")
                .accessibilityLabel("\(card.kind.name): \(card.text). \(card.title), page \(card.page)")
            }
        }
        .frame(maxWidth: 560)
    }
}
