// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation
import Testing
@testable import TextProcessing

/// Covers the renderer that turns the user's personal lexicon into the prompt
/// block appended to an enhance request. Pure string work - no store, no
/// network, no app.
struct PersonalLexiconPromptBlockTests {

    // MARK: - Enabled / Disabled

    @Test func promptBlock_listsEnabledTerms_excludesDisabledOnes() {
        let block = PersonalLexicon.promptBlock(terms: [
            LexiconTerm(original: "缪斯", replacement: "muse"),
            LexiconTerm(original: "拼音", replacement: "pinyin", isEnabled: false)
        ])

        #expect(block.contains("缪斯 => muse"))
        #expect(!block.contains("pinyin"))
        #expect(!block.contains("拼音"))
    }

    @Test func promptBlock_usesTheSharedTag() {
        let block = PersonalLexicon.promptBlock(terms: [
            LexiconTerm(original: "缪斯", replacement: "muse")
        ])

        #expect(block.contains("<\(PersonalLexicon.promptTag)>"))
        #expect(block.contains("</\(PersonalLexicon.promptTag)>"))
        #expect(block.hasPrefix("\n\n<"))
    }

    // MARK: - Empty / Disabled Lexicon

    @Test func promptBlock_emptyLexicon_returnsEmptyString() {
        #expect(PersonalLexicon.promptBlock(terms: []).isEmpty)
    }

    @Test func promptBlock_allTermsDisabled_returnsEmptyString() {
        let block = PersonalLexicon.promptBlock(terms: [
            LexiconTerm(original: "缪斯", replacement: "muse", isEnabled: false),
            LexiconTerm(original: "拼音", replacement: "pinyin", isEnabled: false)
        ])

        #expect(block.isEmpty)
    }

    @Test func promptBlock_blankOrDuplicateTerms_areSkipped() {
        let block = PersonalLexicon.promptBlock(terms: [
            LexiconTerm(original: "  ", replacement: "muse"),
            LexiconTerm(original: "缪斯", replacement: "   "),
            LexiconTerm(original: "缪斯", replacement: "muse"),
            LexiconTerm(original: "缪斯 ", replacement: "muse")
        ])

        // Both survivors normalize to the same pair, so exactly one line lands.
        #expect(block.contains("缪斯 => muse"))
        #expect(block.components(separatedBy: "缪斯 => muse").count == 2)
    }

    // MARK: - Caps

    @Test func promptBlock_stopsAtMaxTerms() {
        let terms = (0..<12).map { LexiconTerm(original: "word\($0)", replacement: "term\($0)") }

        let block = PersonalLexicon.promptBlock(terms: terms, maxTerms: 3)

        #expect(block.contains("word0 => term0"))
        #expect(block.contains("word2 => term2"))
        #expect(!block.contains("word3 => term3"))
    }

    @Test func promptBlock_stopsAtCharacterBudget() {
        let terms = (0..<50).map { LexiconTerm(original: "word\($0)", replacement: "term\($0)") }

        // "word0 => term0" is 14 characters, +1 for its newline: 15 per pair.
        // A 45-character budget fits exactly three of them.
        let block = PersonalLexicon.promptBlock(terms: terms, characterBudget: 45)

        #expect(block.contains("word0 => term0"))
        #expect(block.contains("word2 => term2"))
        #expect(!block.contains("word3 => term3"))
        #expect(block.split(separator: "\n").filter { $0.contains(" => ") }.count == 3)
    }

    @Test func promptBlock_defaultsKeepTheBlockCompact() {
        let terms = (0..<500).map { LexiconTerm(original: "word\($0)", replacement: "term\($0)") }

        let block = PersonalLexicon.promptBlock(terms: terms)

        #expect(block.contains("word0 => term0"))
        #expect(block.count < PersonalLexicon.promptCharacterBudget + 400)
    }
}
