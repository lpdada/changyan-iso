// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation

/// One user-preferred spelling pair from the personal lexicon.
///
/// `original` is the form the recognizer (or a later AI pass) tends to produce,
/// `replacement` is the form the user wants in the final text. A pair can be
/// switched off in Settings, and a switched-off pair must influence nothing -
/// neither the AI prompt nor the deterministic replacement pass.
public struct LexiconTerm: Sendable, Equatable {
    public let original: String
    public let replacement: String
    public let isEnabled: Bool

    public init(original: String, replacement: String, isEnabled: Bool = true) {
        self.original = original
        self.replacement = replacement
        self.isEnabled = isEnabled
    }
}

/// Renders the personal lexicon into the block that is appended to the AI
/// enhance prompt.
///
/// Only the rendering lives here. The pairs themselves are stored by the app
/// and applied deterministically by `ReplacementsService`, so this type stays
/// free of platform frameworks: it is pure string work and can be unit-tested
/// without a model container, a network, or a running app.
public enum PersonalLexicon {
    /// Tag wrapping the block. Follows the shape of the other prompt sections
    /// (`<CUSTOM_VOCABULARY>`, `<CLIPBOARD_CONTEXT>`, `<TRANSCRIPT>`).
    public static let promptTag = "PERSONAL_LEXICON"

    /// Default cap on how many pairs the block may list.
    public static let maxPromptTerms = 50

    /// Default character budget for the rendered pair list. Entries are taken
    /// in order until the budget is spent, so a long entry list can never make
    /// the prompt balloon.
    public static let promptCharacterBudget = 600

    /// Builds the prompt block for the given terms, or an empty string when
    /// there is nothing to say.
    ///
    /// Disabled, blank and duplicate pairs are skipped; the result is empty for
    /// an empty or fully disabled lexicon, which is what keeps the enhance
    /// prompt byte-for-byte unchanged for users who do not use this feature.
    ///
    /// - Parameters:
    ///   - terms: The lexicon, in the order they should be listed.
    ///   - maxTerms: Maximum number of pairs to list.
    ///   - characterBudget: Maximum number of characters spent on listed pairs.
    /// - Returns: `"\n\n<PERSONAL_LEXICON>…</PERSONAL_LEXICON>"`, or `""`.
    public static func promptBlock(
        terms: [LexiconTerm],
        maxTerms: Int = maxPromptTerms,
        characterBudget: Int = promptCharacterBudget
    ) -> String {
        var lines: [String] = []
        var usedCharacters = 0
        var seen = Set<String>()

        for term in terms where term.isEnabled {
            let original = term.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = term.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !replacement.isEmpty else { continue }

            // Collapse repeats so a duplicated pair cannot eat the budget.
            let identity = original.lowercased() + "\u{1}" + replacement.lowercased()
            guard seen.insert(identity).inserted else { continue }

            let line = "\(original) => \(replacement)"
            let cost = line.count + 1 // + the newline that joins it
            guard lines.count < maxTerms, usedCharacters + cost <= characterBudget else { break }

            lines.append(line)
            usedCharacters += cost
        }

        guard !lines.isEmpty else { return "" }

        let instructions = "The speaker's preferred spellings. Wherever the left form appears "
            + "in the transcript, write the right form exactly as given, and never "
            + "\"correct\" these to a different spelling:"
        return "\n\n<\(promptTag)>\(instructions)\n\(lines.joined(separator: "\n"))\n</\(promptTag)>"
    }
}
