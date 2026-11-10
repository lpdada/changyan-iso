//
//  CustomVocabulary.swift
//  VivaDicta
//
//  Created by Anton Novoselov on 2026.01.08
//

import Foundation
import AppGroup
import SwiftData

/// The words the transcribers are biased toward.
///
/// Two sources feed it, in this order:
///
/// 1. the 正确写法 of every 词库 entry (`ReplacementsService.preferredWords`) -
///    the list the user actively maintains, and the reason a bare word with no
///    常见错法 still reaches the local booster, the cloud providers' term lists
///    and the AI prompt;
/// 2. the 词典 list (`VocabularyWord`, Settings → 拼写纠正).
///
/// 词库 entries come first because the providers cap the list (`maxTerms`) and
/// the words the user typed into the lexicon should never be the ones cut.
enum CustomVocabulary {
    /// Set once at app startup to enable SwiftData-backed vocabulary lookups
    static var modelContainer: ModelContainer?

    /// Retrieves custom vocabulary terms from SwiftData, deduplicated and optionally limited.
    /// - Parameter maxTerms: Optional maximum number of terms to return. If nil, returns all terms.
    /// - Returns: Array of unique vocabulary terms, 词库 words first, then the
    ///   词典 list in alphabetical order.
    static func getTerms(maxTerms: Int? = nil) -> [String] {
        guard let container = modelContainer else { return [] }

        let context = ModelContext(container)

        var words: [String] = []

        // 词库: gated by its own switch inside `preferredWords`, so turning off
        // 拼写纠正 leaves these alone and vice versa.
        words.append(contentsOf: ReplacementsService.preferredWords(context: context))

        // 词典 (拼写纠正) list.
        let isSpellingCorrectionsEnabled =
            UserDefaultsStorage.appPrivate.object(forKey: UserDefaultsStorage.Keys.isSpellingCorrectionsEnabled) as? Bool ?? true
        if isSpellingCorrectionsEnabled {
            let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
            let items = (try? context.fetch(descriptor)) ?? []
            let dictionaryWords = items
                .map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            words.append(contentsOf: dictionaryWords)
        }

        guard !words.isEmpty else { return [] }

        // De-duplicate while preserving order
        var seen = Set<String>()
        var unique: [String] = []
        for word in words {
            let key = word.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(word)
            }
            if let max = maxTerms, unique.count >= max {
                break
            }
        }
        return unique
    }
}
