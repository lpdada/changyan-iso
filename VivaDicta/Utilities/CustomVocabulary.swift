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
/// Two sources feed it: the 词典 list (`VocabularyWord`, Settings → 拼写纠正) and
/// the 正确写法 of every 词库 entry (Settings → 词库). The second source is what
/// lets the user add a word *without* writing a replacement rule - the word
/// still reaches the local booster, the cloud providers' term lists and the AI
/// prompt.
enum CustomVocabulary {
    /// Set once at app startup to enable SwiftData-backed vocabulary lookups
    static var modelContainer: ModelContainer?

    /// Retrieves custom vocabulary terms from SwiftData, deduplicated and optionally limited.
    /// - Parameter maxTerms: Optional maximum number of terms to return. If nil, returns all terms.
    /// - Returns: Array of unique vocabulary terms, preserving original order. Returns empty array if spelling corrections are disabled.
    static func getTerms(maxTerms: Int? = nil) -> [String] {
        // Check if spelling corrections are enabled
        let isEnabled = UserDefaultsStorage.appPrivate.object(forKey: UserDefaultsStorage.Keys.isSpellingCorrectionsEnabled) as? Bool ?? true
        guard isEnabled else { return [] }

        guard let container = modelContainer else { return [] }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])

        let items = (try? context.fetch(descriptor)) ?? []

        var words = items.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        // 词库 entries contribute their 正确写法 whether or not they also name a
        // 常见错法: recognition-only entries are the whole point of that screen.
        words.append(contentsOf: ReplacementsService.preferredWords(context: context))

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
