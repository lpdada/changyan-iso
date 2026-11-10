// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation
import SwiftData
import Testing
@testable import VivaDicta

/// The personal lexicon end to end, minus the network: "词库" entries must
/// reach the AI enhance prompt, must still be applied to the AI output, and must
/// change nothing when the lexicon is empty, fully disabled, or switched off
/// globally. An entry that carries only the 正确写法 (no 常见错法) must bias
/// recognition without ever rewriting text.
///
/// The app-level half of the coverage - the pure renderer is covered by
/// `TextProcessingTests/PersonalLexiconPromptBlockTests`.
@MainActor
struct PersonalLexiconTests {

    // MARK: - Fixtures

    /// Hermetic store holding just the schemas these tests touch.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: WordReplacement.self,
            configurations: .init(isStoredInMemoryOnly: true)
        )
        return container.mainContext
    }

    private func insert(
        _ original: String,
        _ replacement: String,
        isEnabled: Bool = true,
        into context: ModelContext
    ) throws {
        context.insert(
            WordReplacement(
                originalText: original,
                replacementText: replacement,
                isEnabled: isEnabled
            )
        )
        try context.save()
    }

    /// `AIService` on an isolated defaults suite, so no real settings are read.
    private func makeAIService() -> (service: AIService, defaults: UserDefaults, suiteName: String) {
        let suiteName = "PersonalLexiconTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return (AIService(userDefaults: defaults), defaults, suiteName)
    }

    // MARK: - Prompt layer

    @Test func lexiconPromptBlock_listsEnabledEntriesOnly() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)
        try insert("拼音", "pinyin", isEnabled: false, into: context)

        let block = ReplacementsService.lexiconPromptBlock(context: context, isEnabled: true)

        #expect(block.contains("<PERSONAL_LEXICON>"))
        #expect(block.contains("缪斯 => muse"))
        // A disabled entry must not reach the prompt at all.
        #expect(!block.contains("pinyin"))
        #expect(!block.contains("拼音"))
    }

    @Test func lexiconPromptBlock_expandsCommaSeparatedVariants() throws {
        let context = try makeContext()
        try insert("缪斯, 缪丝", "muse", into: context)

        let block = ReplacementsService.lexiconPromptBlock(context: context, isEnabled: true)

        #expect(block.contains("缪斯 => muse"))
        #expect(block.contains("缪丝 => muse"))
    }

    @Test func lexiconPromptBlock_emptyLexicon_isEmpty() throws {
        let context = try makeContext()

        #expect(ReplacementsService.lexiconPromptBlock(context: context).isEmpty)
    }

    /// The switch is passed explicitly here rather than flipped in the shared
    /// defaults: the suite runs in parallel, and process-wide state would make
    /// these expectations racy.
    @Test func lexiconPromptBlock_globalSwitchOff_isEmpty() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)

        #expect(ReplacementsService.lexiconPromptBlock(context: context, isEnabled: true).contains("muse"))
        #expect(ReplacementsService.lexiconPromptBlock(context: context, isEnabled: false).isEmpty)
    }

    // MARK: - Prompt composition (the enhance system prompt)

    @Test func enhancePromptContextSections_embedsTheLexiconBlock() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)
        let block = ReplacementsService.lexiconPromptBlock(context: context, isEnabled: true)

        let (service, defaults, suiteName) = makeAIService()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let withLexicon = service.enhancePromptContextSections(lexiconSection: block)
        #expect(withLexicon.contains("<PERSONAL_LEXICON>"))
        #expect(withLexicon.contains("缪斯 => muse"))
    }

    @Test func enhancePromptContextSections_withoutLexicon_matchThePreviousPrompt() throws {
        let (service, defaults, suiteName) = makeAIService()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sections = service.enhancePromptContextSections(lexiconSection: "")

        #expect(!sections.contains("<PERSONAL_LEXICON>"))
    }

    // MARK: - Final layer (after enhancement)

    @Test func applyReplacementsIfEnabled_restoresPreferredSpellingAfterEnhancement() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)

        // What a model does when it "helpfully" fixes the foreign-looking word.
        let modelOutput = "今天聊了缪斯，还有缪斯的专辑。"

        let final = ReplacementsService.applyReplacementsIfEnabled(to: modelOutput, context: context, isEnabled: true)

        #expect(final == "今天聊了muse，还有muse的专辑。")
    }

    @Test func applyReplacementsIfEnabled_isIdempotent() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)

        let once = ReplacementsService.applyReplacementsIfEnabled(to: "缪斯", context: context, isEnabled: true)
        let twice = ReplacementsService.applyReplacementsIfEnabled(to: once, context: context, isEnabled: true)

        #expect(once == "muse")
        #expect(twice == "muse")
    }

    @Test func applyReplacementsIfEnabled_doesNotFireInsideUnrelatedWords() throws {
        let context = try makeContext()
        try insert("cat", "dog", into: context)

        let final = ReplacementsService.applyReplacementsIfEnabled(
            to: "concatenate the cat, category",
            context: context,
            isEnabled: true
        )

        #expect(final == "concatenate the dog, category")
    }

    @Test func applyReplacementsIfEnabled_emptyLexicon_leavesTextUntouched() throws {
        let context = try makeContext()
        let text = "缪斯 stays exactly as it is"

        #expect(ReplacementsService.applyReplacementsIfEnabled(to: text, context: context, isEnabled: true) == text)
    }

    @Test func applyReplacementsIfEnabled_globalSwitchOff_leavesTextUntouched() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)

        #expect(ReplacementsService.applyReplacementsIfEnabled(to: "缪斯", context: context, isEnabled: true) == "muse")
        #expect(ReplacementsService.applyReplacementsIfEnabled(to: "缪斯", context: context, isEnabled: false) == "缪斯")
    }

    // MARK: - Recognition-only entries (正确写法 without 常见错法)

    @Test func recognitionOnlyEntry_reachesThePromptAsABareWord() throws {
        let context = try makeContext()
        try insert("", "muse", into: context)

        let block = ReplacementsService.lexiconPromptBlock(context: context, isEnabled: true)

        #expect(block.contains("<PERSONAL_LEXICON>"))
        #expect(block.contains("muse"))
        // No 常见错法 means no pair rendering at all.
        #expect(!block.contains("=>"))
    }

    @Test func recognitionOnlyEntry_neverRewritesText() throws {
        let context = try makeContext()
        try insert("", "muse", into: context)

        let text = "今天聊了缪斯和他的专辑。"
        let final = ReplacementsService.applyReplacementsIfEnabled(to: text, context: context, isEnabled: true)

        #expect(final == text)
    }

    @Test func recognitionOnlyEntry_joinsTheVocabularyTerms() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)
        try insert("", "muse get", into: context)

        let words = ReplacementsService.preferredWords(context: context, isEnabled: true)

        #expect(words == ["muse", "muse get"])
    }

    @Test func preferredWords_areDeduplicated() throws {
        let context = try makeContext()
        try insert("缪斯", "muse", into: context)
        try insert("", "Muse", into: context)

        #expect(ReplacementsService.preferredWords(context: context, isEnabled: true) == ["muse"])
    }

    @Test func preferredWords_respectTheGlobalSwitch() throws {
        let context = try makeContext()
        try insert("", "muse", into: context)

        #expect(ReplacementsService.preferredWords(context: context, isEnabled: true) == ["muse"])
        #expect(ReplacementsService.preferredWords(context: context, isEnabled: false).isEmpty)
    }

    @Test func misrecognitions_acceptChineseAndFullWidthSeparators() throws {
        let context = try makeContext()
        try insert("缪斯、缪丝，谬斯", "muse", into: context)

        let block = ReplacementsService.lexiconPromptBlock(context: context, isEnabled: true)

        #expect(block.contains("缪斯 => muse"))
        #expect(block.contains("缪丝 => muse"))
        #expect(block.contains("谬斯 => muse"))
    }
}
