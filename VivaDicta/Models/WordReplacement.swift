import Foundation
import SwiftData

/// One personal-lexicon entry (Settings → 词库).
///
/// The stored layout is historical: `replacementText` is the **正确写法** - the
/// word the user wants - and `originalText` is the optional **常见错法** list
/// (comma / 顿号 separated). Keeping the old property names means existing
/// installs keep their entries without a migration step; the accessors below
/// give the code the vocabulary it actually means.
@Model
final class WordReplacement {
    var originalText: String = ""
    var replacementText: String = ""
    var dateAdded: Date = Date()
    var isEnabled: Bool = true

    init(originalText: String, replacementText: String, dateAdded: Date = Date(), isEnabled: Bool = true) {
        self.originalText = originalText
        self.replacementText = replacementText
        self.dateAdded = dateAdded
        self.isEnabled = isEnabled
    }
}

extension WordReplacement {
    /// 正确写法: the spelling that should come out of the dictation. Empty means
    /// the entry is effectively blank and takes part in nothing.
    var preferredSpelling: String {
        replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 常见错法: forms the pipeline used to produce instead, split on the
    /// separators the Settings screen advertises (comma, 顿号, semicolon).
    /// Empty when the user only wants the word to be recognized.
    var misrecognitions: [String] {
        originalText
            .split(whereSeparator: { Self.misrecognitionSeparators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True for entries that only nudge recognition and never rewrite text.
    var isRecognitionOnly: Bool {
        misrecognitions.isEmpty
    }

    private static let misrecognitionSeparators: Set<Character> = [
        ",", "，", "、", ";", "；", "/", "|"
    ]
}
