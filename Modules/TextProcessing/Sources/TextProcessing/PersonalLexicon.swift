// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation

/// One entry of the personal lexicon (Settings → 词库).
///
/// An entry is first of all **one word the speaker wants**: `replacement` is the
/// spelling that should come out of the dictation. The optional `original` is the
/// form the recognizer (or a later AI pass) used to produce instead; when it is
/// empty the entry is recognition-only - it biases the pipeline toward the word
/// without rewriting anything. That is what makes "just add 常用词" work: the user
/// types `muse`, leaves 常见错法 blank, and gets `muse` out of an `缪斯`-ish
/// utterance.
///
/// A pair can be switched off in Settings, and a switched-off entry must
/// influence nothing - neither the AI prompt nor the deterministic replacement
/// pass.
public struct LexiconTerm: Sendable, Equatable {
    /// The form that used to come out of the pipeline (常见错法). Blank for a
    /// recognition-only term.
    public let original: String
    /// The form the user wants in the final text (正确写法).
    public let replacement: String
    public let isEnabled: Bool

    public init(original: String, replacement: String, isEnabled: Bool = true) {
        self.original = original
        self.replacement = replacement
        self.isEnabled = isEnabled
    }

    /// A term that only asks the pipeline to prefer a word - no rewriting.
    public init(term: String, isEnabled: Bool = true) {
        self.init(original: "", replacement: term, isEnabled: isEnabled)
    }

    /// True when the entry carries no 常见错法 and therefore must never run as a
    /// replacement rule.
    public var isRecognitionOnly: Bool {
        original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Renders the personal lexicon into the block that is appended to the AI
/// enhance prompt.
///
/// Only the rendering lives here. The entries themselves are stored by the app
/// and applied deterministically by `ReplacementsService`, so this type stays
/// free of platform frameworks: it is pure string work and can be unit-tested
/// without a model container, a network, or a running app.
public enum PersonalLexicon {
    /// Tag wrapping the block. Follows the shape of the other prompt sections
    /// (`<CUSTOM_VOCABULARY>`, `<CLIPBOARD_CONTEXT>`, `<TRANSCRIPT>`).
    public static let promptTag = "PERSONAL_LEXICON"

    /// Default cap on how many entries the block may list.
    public static let maxPromptTerms = 50

    /// Default character budget for the rendered list. Entries are taken in
    /// order until the budget is spent, so a long entry list can never make the
    /// prompt balloon.
    public static let promptCharacterBudget = 600

    /// Instruction that precedes the recognition-only words.
    static let recognitionOnlyInstruction =
        "The speaker's own words. Whenever the audio merely *sounds like* one of "
        + "these, write it exactly in this spelling - never translate it, "
        + "transliterate it, or swap in a more common word:"

    /// Instruction that precedes the `wrong => right` pairs.
    static let pairInstruction =
        "The speaker's preferred spellings. Wherever the left form appears "
        + "in the transcript, write the right form exactly as given, and never "
        + "\"correct\" these to a different spelling:"

    /// Builds the prompt block for the given terms, or an empty string when
    /// there is nothing to say.
    ///
    /// Disabled, blank and duplicate entries are skipped; the result is empty for
    /// an empty or fully disabled lexicon, which is what keeps the enhance
    /// prompt byte-for-byte unchanged for users who do not use this feature.
    ///
    /// Recognition-only entries are listed as bare words, pairs as
    /// `wrong => right`; both share one cap and one character budget so the
    /// block stays compact.
    ///
    /// - Parameters:
    ///   - terms: The lexicon, in the order they should be listed.
    ///   - maxTerms: Maximum number of entries to list.
    ///   - characterBudget: Maximum number of characters spent on listed entries.
    /// - Returns: `"\n\n<PERSONAL_LEXICON>…</PERSONAL_LEXICON>"`, or `""`.
    public static func promptBlock(
        terms: [LexiconTerm],
        maxTerms: Int = maxPromptTerms,
        characterBudget: Int = promptCharacterBudget
    ) -> String {
        var words: [String] = []
        var pairs: [String] = []
        var usedCharacters = 0
        var listed = 0
        var seen = Set<String>()

        for term in terms where term.isEnabled {
            let original = term.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = term.replacement.trimmingCharacters(in: .whitespacesAndNewlines)

            // The wanted spelling is what makes an entry meaningful; 常见错法 is
            // optional by design.
            guard !replacement.isEmpty else { continue }

            let isRecognitionOnly = original.isEmpty
            // Collapse repeats so a duplicated entry cannot eat the budget.
            let identity = isRecognitionOnly
                ? "\u{1}" + replacement.lowercased()
                : original.lowercased() + "\u{1}" + replacement.lowercased()
            guard seen.insert(identity).inserted else { continue }

            let line = isRecognitionOnly ? replacement : "\(original) => \(replacement)"
            let cost = line.count + 1 // + the newline that joins it
            guard listed < maxTerms, usedCharacters + cost <= characterBudget else { break }

            if isRecognitionOnly {
                words.append(line)
            } else {
                pairs.append(line)
            }
            listed += 1
            usedCharacters += cost
        }

        guard !words.isEmpty || !pairs.isEmpty else { return "" }

        var sections: [String] = []
        if !words.isEmpty {
            sections.append(recognitionOnlyInstruction + "\n" + words.joined(separator: "\n"))
        }
        if !pairs.isEmpty {
            sections.append(pairInstruction + "\n" + pairs.joined(separator: "\n"))
        }

        let body = sections.joined(separator: "\n")
        return "\n\n<\(promptTag)>\(body)\n</\(promptTag)>"
    }
}
