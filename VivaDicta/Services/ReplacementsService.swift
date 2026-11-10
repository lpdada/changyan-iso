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

/// Provides word replacement functionality backed by SwiftData.
/// The static `applyReplacements(to:)` method is used in the transcription pipeline.
/// CRUD operations happen directly via `ModelContext` in views.
///
/// The same rules are also the user's personal lexicon (Settings → 词语替换):
/// besides the pass inside the transcription pipeline
/// (`TranscriptionManager.postProcess`), they feed the AI enhance prompt
/// (`lexiconPromptBlock`) and are applied again to the AI output
/// (`applyReplacementsIfEnabled`) - see ``RecordViewModel/applyPersonalLexicon``.
/// Between the two layers a preferred spelling such as "缪斯 → muse" sticks no
/// matter what the model does with it.
enum ReplacementsService {
    /// Maximum character length for original or replacement text
    static let maxTextLength = 100

    /// Set once at app startup to enable SwiftData-backed replacement lookups
    static var modelContainer: ModelContainer?

    // MARK: - Global Toggle

    /// Whether the user's replacement rules participate at all - the global
    /// "启用替换规则" switch in Settings. Both layers respect it, so turning it
    /// off leaves the final text and the enhance prompt exactly as they were.
    static var isGloballyEnabled: Bool {
        UserDefaultsStorage.appPrivate.object(forKey: UserDefaultsStorage.Keys.isReplacementsEnabled) as? Bool ?? true
    }

    // MARK: - Apply Replacements

    /// Applies all enabled replacements from SwiftData to the given text.
    ///
    /// - Parameters:
    ///   - text: Text to rewrite.
    ///   - context: SwiftData context to read the rules from. `nil` uses the
    ///     app-wide container set at launch; callers that already own a context
    ///     (background work, tests) can pass theirs.
    static func applyReplacements(to text: String, context: ModelContext? = nil) -> String {
        let replacements = enabledReplacements(context: context)

        guard !replacements.isEmpty else {
            return text
        }

        var modifiedText = text

        for replacement in replacements {
            let replacementText = replacement.replacementText

            for original in variants(of: replacement.originalText) {
                let usesBoundaries = usesWordBoundaries(for: original)

                if usesBoundaries {
                    let escapedOriginal = NSRegularExpression.escapedPattern(for: original)
                    if let regex = try? Regex("\\b\(escapedOriginal)\\b").ignoresCase() {
                        modifiedText = modifiedText.replacing(regex, with: replacementText)
                    }
                } else {
                    if let regex = try? Regex(NSRegularExpression.escapedPattern(for: original)).ignoresCase() {
                        modifiedText = modifiedText.replacing(regex, with: replacementText)
                    }
                }
            }
        }

        return modifiedText
    }

    /// Applies the replacements to text the AI produced, unless the user turned
    /// the feature off entirely.
    ///
    /// This is the final layer: the transcription pipeline runs the
    /// replacements *before* enhancement, so a model that "corrects" a
    /// preferred spelling back would otherwise win. Running the same rules over
    /// the enhanced text - and over anything the keyboard receives - is what
    /// makes the lexicon stick.
    ///
    /// - Parameters:
    ///   - text: Text to rewrite.
    ///   - context: SwiftData context to read the rules from; `nil` uses the
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

    // MARK: - Lexicon Prompt Block

    /// The enabled rules as lexicon terms, one term per comma-separated
    /// original (same split the replacement pass uses).
    static func enabledTerms(context: ModelContext? = nil) -> [LexiconTerm] {
        enabledReplacements(context: context).flatMap { replacement in
            variants(of: replacement.originalText).map { original in
                LexiconTerm(
                    original: original,
                    replacement: replacement.replacementText,
                    isEnabled: replacement.isEnabled
                )
            }
        }
    }

    /// The `<PERSONAL_LEXICON>` block appended to the AI enhance prompt so the
    /// model preserves the user's preferred spellings instead of "correcting"
    /// them. Empty when the feature is off or nothing is enabled, which keeps
    /// the prompt unchanged for everyone else.
    /// - Parameters:
    ///   - context: SwiftData context to read the rules from; `nil` uses the
    ///     app-wide container.
    ///   - isEnabled: The global switch. `nil` (the default) reads the stored
    ///     preference; an explicit value is honored as-is (tests use this).
    ///   - maxTerms: Maximum number of pairs to list.
    ///   - characterBudget: Maximum number of characters spent on listed pairs.
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

    /// Enabled rules in the order the user added them, so both layers behave
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

    /// Splits comma-separated originals at apply time
    private static func variants(of originalText: String) -> [String] {
        originalText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
