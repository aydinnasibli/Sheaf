import AppKit
import SwiftUI

/// The four highlighters. Each color has a meaning, chosen with keys 1–4.
enum HighlightKind: Int, CaseIterable, Identifiable, Codable {
    case keyIdea = 1
    case question = 2
    case definition = 3
    case evidence = 4

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .keyIdea: "Key idea"
        case .question: "Question"
        case .definition: "Definition"
        case .evidence: "Evidence"
        }
    }

    /// The highlight drawn on the page. Pages stay paper-white in Dark Mode,
    /// so this color doesn't change with the appearance.
    var pageColor: NSColor { NSColor(hex: pageColorHex) }

    var pageColorHex: UInt32 {
        switch self {
        case .keyIdea: 0xFFE066
        case .question: 0xFFC2D1
        case .definition: 0xA5D8FF
        case .evidence: 0xB2F2BB
        }
    }

    /// Full-strength version used in the wordmark and progress markers.
    var vivid: Color {
        switch self {
        case .keyIdea: Color(light: 0xFFD43B, dark: 0xFFD43B)
        case .question: Color(light: 0xFF8FAB, dark: 0xFF8FAB)
        case .definition: Color(light: 0x74C0FC, dark: 0x74C0FC)
        case .evidence: Color(light: 0x8CE99A, dark: 0x69DB7C)
        }
    }

    /// What each color is for, shown in the library.
    var purpose: String {
        switch self {
        case .keyIdea: "The main points"
        case .question: "Things to check or ask"
        case .definition: "Terms to remember"
        case .evidence: "Data and quotes to cite"
        }
    }

    /// Background of chips and cards for this kind: the light highlighter
    /// color in Light Mode, a dark tint of it in Dark Mode.
    var chipBackground: Color {
        switch self {
        case .keyIdea: Color(light: 0xFFE066, dark: 0x3B341C)
        case .question: Color(light: 0xFFC2D1, dark: 0x3B292E)
        case .definition: Color(light: 0xA5D8FF, dark: 0x25313B)
        case .evidence: Color(light: 0xB2F2BB, dark: 0x233626)
        }
    }

    /// Text on `chipBackground`.
    var chipText: Color {
        switch self {
        case .keyIdea: Color(light: 0x111111, dark: 0xFFD43B)
        case .question: Color(light: 0x111111, dark: 0xFF8FAB)
        case .definition: Color(light: 0x111111, dark: 0x74C0FC)
        case .evidence: Color(light: 0x111111, dark: 0x69DB7C)
        }
    }

    /// The color in the interface: swatches, legends and filter chips.
    /// Brighter in Dark Mode so it stands out on dark surfaces.
    var swatch: Color {
        switch self {
        case .keyIdea: Color(light: 0xFFE066, dark: 0xFFD43B)
        case .question: Color(light: 0xFFC2D1, dark: 0xFF8FAB)
        case .definition: Color(light: 0xA5D8FF, dark: 0x74C0FC)
        case .evidence: Color(light: 0xB2F2BB, dark: 0x69DB7C)
        }
    }
}
