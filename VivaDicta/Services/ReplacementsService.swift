//
//  ReplacementsService.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2025.12.10
//

import Foundation
import SwiftUI
import SwiftData
import AppGroup
import TextProcessing
import os

/// The user's personal lexicon (Settings → 词库), backed by SwiftData.
///
/// An entry is a **word the user wants** (`replacementText` / 正确写法) plus an
/// optional list of the forms the pipeline used to produce instead
/// (`originalText` / 常见错法). Two layers come out of that:
///
/// - **Recognition**: every entry's 正确写法 is offered to the transcribers and
///   to the AI enhance prompt as a word the speaker uses (``preferredWords``,
///   ``lexiconPromptBlock``). An entry without 常见错法 stops here - it nudges
///   the recognizer toward the word and rewrites nothing.
/// - **Replacement**: an entry *with* 常见错法 additionally rewrites those forms
///   to 正确写法, once inside the transcription pipeline
///   (`TranscriptionManager.postProcess`) and once more on the AI output
///   (`applyReplacementsIfEnabled`, see ``RecordViewModel/applyPersonalLexicon``).
///   Between the two layers a preferred spelling such as "缪斯 → muse" sticks no
///   matter what the model does with it.
enum ReplacementsService {
    /// Maximum character length for the preferred spelling or the 常见错法 list
    static let maxTextLength = 100

    /// Set once at app startup to enable SwiftData-backed replacement lookups
    static var modelContainer: ModelContainer?

    // MARK: - Global Toggle

    /// Whether the user's lexicon participates at all - the global
    /// "启用词库" switch in Settings. Every layer respects it, so turning it
    /// off leaves the final text and the enhance prompt exactly as they were.
    static var isGloballyEnabled: Bool {
        UserDefaultsStorage.appPrivate.object(forKey: UserDefaultsStorage.Keys.isReplacementsEnabled) as? Bool ?? true
    }

    // MARK: - Apply Replacements

    /// Applies the 常见错法 → 正确写法 rules of all enabled entries to the text.
    ///
    /// Recognition-only entries have no 常见错法, so they contribute nothing
    /// here by construction - adding a word to the lexicon never rewrites text.
    ///
    /// - Parameters:
    ///   - text: Text to rewrite.
    ///   - context: SwiftData context to read the entries from. `nil` uses the
    ///     app-wide container set at launch; callers that already own a context
    ///     (background work, tests) can pass theirs.
    static func applyReplacements(to text: String, context: ModelContext? = nil) -> String {
        let replacements = enabledReplacements(context: context)

        guard !replacements.isEmpty else {
            return text
        }

        var modifiedText = text

        for replacement in replacements {
            let preferred = replacement.preferredSpelling
            guard !preferred.isEmpty else { continue }

            for original in replacement.misrecognitions {
                let usesBoundaries = usesWordBoundaries(for: original)

                if usesBoundaries {
                    let escapedOriginal = NSRegularExpression.escapedPattern(for: original)
                    if let regex = try? Regex("\\b\(escapedOriginal)\\b").ignoresCase() {
                        modifiedText = modifiedText.replacing(regex, with: preferred)
                    }
                } else {
                    if let regex = try? Regex(NSRegularExpression.escapedPattern(for: original)).ignoresCase() {
                        modifiedText = modifiedText.replacing(regex, with: preferred)
                    }
                }
            }
        }

        return modifiedText
    }

    /// Applies the replacement rules to text the AI produced, unless the user
    /// turned the feature off entirely.
    ///
    /// This is the final layer: the transcription pipeline runs the
    /// replacements *before* enhancement, so a model that "corrects" a
    /// preferred spelling back would otherwise win. Running the same rules over
    /// the enhanced text - and over anything the keyboard receives - is what
    /// makes the lexicon stick.
    ///
    /// - Parameters:
    ///   - text: Text to rewrite.
    ///   - context: SwiftData context to read the entries from; `nil` uses the
    ///     app-wide container.
    ///   - isEnabled: The global switch. `nil` (the default) reads the stored
    ///     preference; an explicit value is honored as-is, which is what tests
    ///     use so they never have to touch process-wide defaults.
    static func applyReplacementsIfEnabled(
        to text: String,
        context: ModelContext? = nil,
        isEnabled: Bool? = nil
    ) -> String {
        guard isEnabled ?? isGloballyEnabled else { return text }
        return applyReplacements(to: text, context: context)
    }

    // MARK: - Recognition Layer

    /// The enabled entries as lexicon terms: one term per comma-separated
    /// 常见错法, or a single recognition-only term when the user left 常见错法
    /// blank. Order follows `dateAdded` so both layers behave deterministically.
    static func enabledTerms(context: ModelContext? = nil) -> [LexiconTerm] {
        enabledReplacements(context: context).flatMap { replacement -> [LexiconTerm] in
            let preferred = replacement.preferredSpelling
            guard !preferred.isEmpty else { return [] }
            guard replacement.isEnabled else { return [] }

            let misrecognitions = replacement.misrecognitions
            guard !misrecognitions.isEmpty else {
                return [LexiconTerm(term: preferred, isEnabled: true)]
            }
            return misrecognitions.map { original in
                LexiconTerm(original: original, replacement: preferred, isEnabled: true)
            }
        }
    }

    /// The 正确写法 of every enabled entry, deduplicated - the words the
    /// recognizers are biased toward and the AI prompt is told the speaker uses.
    ///
    /// This is what makes "I only added the word, no 常见错法" behave like the
    /// desktop app: the entry reaches every recognition layer without becoming
    /// a rigid find-and-replace rule.
    ///
    /// - Parameters:
    ///   - context: SwiftData context to read the entries from; `nil` uses the
    ///     app-wide container.
    ///   - isEnabled: The global switch; `nil` reads the stored preference.
    ///   - maxTerms: Optional cap on how many words are returned.
    static func preferredWords(
        context: ModelContext? = nil,
        isEnabled: Bool? = nil,
        maxTerms: Int? = nil
    ) -> [String] {
        guard isEnabled ?? isGloballyEnabled else { return [] }

        var seen = Set<String>()
        var words: [String] = []

        for replacement in enabledReplacements(context: context) {
            let word = replacement.preferredSpelling
            guard !word.isEmpty else { continue }
            guard seen.insert(word.lowercased()).inserted else { continue }

            words.append(word)
            if let maxTerms, words.count >= maxTerms { break }
        }

        return words
    }

    /// The `<PERSONAL_LEXICON>` block appended to the AI enhance prompt so the
    /// model preserves the user's preferred spellings instead of "correcting"
    /// them, and knows which words the speaker uses. Empty when the feature is
    /// off or nothing is enabled, which keeps the prompt unchanged for everyone
    /// else.
    /// - Parameters:
    ///   - context: SwiftData context to read the entries from; `nil` uses the
    ///     app-wide container.
    ///   - isEnabled: The global switch. `nil` (the default) reads the stored
    ///     preference; an explicit value is honored as-is (tests use this).
    ///   - maxTerms: Maximum number of entries to list.
    ///   - characterBudget: Maximum number of characters spent on listed entries.
    static func lexiconPromptBlock(
        context: ModelContext? = nil,
        isEnabled: Bool? = nil,
        maxTerms: Int = PersonalLexicon.maxPromptTerms,
        characterBudget: Int = PersonalLexicon.promptCharacterBudget
    ) -> String {
        guard isEnabled ?? isGloballyEnabled else { return "" }
        return PersonalLexicon.promptBlock(
            terms: enabledTerms(context: context),
            maxTerms: maxTerms,
            characterBudget: characterBudget
        )
    }

    // MARK: - Fetching

    /// Enabled entries in the order the user added them, so both layers behave
    /// deterministically when two rules could match the same text.
    private static func enabledReplacements(context: ModelContext? = nil) -> [WordReplacement] {
        guard let context = context ?? makeContext() else { return [] }

        let descriptor = FetchDescriptor<WordReplacement>(
            predicate: #Predicate { $0.isEnabled },
            sortBy: [SortDescriptor(\.dateAdded)]
        )

        return (try? context.fetch(descriptor)) ?? []
    }

    private static func makeContext() -> ModelContext? {
        guard let container = modelContainer else { return nil }
        return ModelContext(container)
    }

    // MARK: - Script Detection

    /// Returns false for languages without spaces (CJK, Thai), true for spaced languages
    static func usesWordBoundaries(for text: String) -> Bool {
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F, // Hiragana
            0x30A0...0x30FF, // Katakana
            0x4E00...0x9FFF, // CJK Unified Ideographs
            0xAC00...0xD7AF, // Hangul Syllables
            0x0E00...0x0E7F  // Thai
        ]

        for scalar in text.unicodeScalars {
            for range in nonSpacedScripts {
                if range.contains(scalar.value) {
                    return false
                }
            }
        }

        return true
    }
}

// MARK: - Legacy Replacement Model (kept for migration decoding and tests)

struct Replacement: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    let original: String
    let replacement: String

    init(id: UUID = UUID(), original: String, replacement: String) {
        self.id = id
        self.original = original
        self.replacement = replacement
    }
}
