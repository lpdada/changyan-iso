// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation

/// Merges the self-hosted streaming server's segments into one dictation text.
///
/// The meeting screen keeps every segment as its own row; dictation has to end
/// up as a single string. Two rules make that safe:
///
/// - **Segments are keyed by the server's `segment_id`, never by arrival
///   position.** An interim frame updates its segment in place, and the final
///   frame for the same id replaces that text - so a phrase that firms up is
///   never counted twice.
/// - **The offline-corrected final wins.** The endpoint runs offline correction
///   over the streaming output when `offline_correction` is on, and delivers the
///   result as the segment's final text. A plain final that arrives after a
///   corrected one for the same id is ignored rather than allowed to undo the
///   correction.
///
/// Joining is script-aware: adjacent CJK text is concatenated as-is, while
/// Latin-script segments get a single space - the server does not guarantee
/// leading whitespace on segment boundaries.
///
/// Pure value type, Foundation-only: the session actor owns one, and the rules
/// above are tested directly (on CI, and by the Linux harness) rather than
/// inferred from a live transcript.
///
/// `nonisolated` so the dictation actor (`SelfHostedRealtimeSession`) can read
/// and mutate it. Without it Swift 6 infers MainActor isolation for this type
/// and the actor cannot touch its own transcript.
nonisolated struct SelfHostedStreamingTranscript: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        /// The server's `segment_id`. Identity for every update.
        let segmentID: String
        var text: String
        var isFinal: Bool
        /// True once the segment's text came from the server's offline
        /// correction pass.
        var corrected: Bool
    }

    /// In first-appearance order. Order only ever changes by appending, so the
    /// joined text never reshuffles.
    private(set) var segments: [Segment] = []

    var isEmpty: Bool {
        segments.allSatisfy { $0.text.isEmpty }
    }

    /// Finals only - what the server has committed to.
    var finalText: String {
        Self.join(segments.filter(\.isFinal).map(\.text))
    }

    /// Finals plus any segment still provisional: the full recording, with the
    /// tail at whatever the server last believed.
    var text: String {
        Self.join(segments.map(\.text))
    }

    mutating func applyInterim(segmentID: String, text: String) {
        let cleaned = Self.cleaned(text)
        guard !cleaned.isEmpty else { return }

        guard let index = index(of: segmentID) else {
            segments.append(Segment(
                segmentID: segmentID,
                text: cleaned,
                isFinal: false,
                corrected: false
            ))
            return
        }

        // A final is authoritative; a late interim for the same id must not
        // water it back down.
        guard !segments[index].isFinal else { return }
        segments[index].text = cleaned
    }

    mutating func applyFinal(segmentID: String, text: String, corrected: Bool) {
        let cleaned = Self.cleaned(text)

        guard let index = index(of: segmentID) else {
            guard !cleaned.isEmpty else { return }
            segments.append(Segment(
                segmentID: segmentID,
                text: cleaned,
                isFinal: true,
                corrected: corrected
            ))
            return
        }

        // Offline-corrected text outranks a plain final for the same segment.
        if segments[index].isFinal, segments[index].corrected, !corrected { return }

        if !cleaned.isEmpty {
            segments[index].text = cleaned
        }
        segments[index].isFinal = true
        segments[index].corrected = corrected
    }

    mutating func reset() {
        segments.removeAll()
    }

    private func index(of segmentID: String) -> Int? {
        segments.firstIndex { $0.segmentID == segmentID }
    }

    // MARK: - Joining

    /// Concatenates segment texts with the separator their scripts call for.
    static func join(_ texts: [String]) -> String {
        var result = ""
        for raw in texts {
            let piece = cleaned(raw)
            guard !piece.isEmpty else { continue }
            guard !result.isEmpty else {
                result = piece
                continue
            }
            result += separator(between: result, and: piece) + piece
        }
        return result
    }

    /// Segment text without the padding the server sometimes adds around it.
    static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func separator(between left: String, and right: String) -> String {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else {
            return ""
        }
        // Already separated, or separated by the other side's own padding.
        if CharacterSet.whitespacesAndNewlines.contains(last)
            || CharacterSet.whitespacesAndNewlines.contains(first) {
            return ""
        }
        // CJK does not space its words, and the server emits no space either.
        if isCJK(last) || isCJK(first) {
            return ""
        }
        return " "
    }

    /// Han, kana, Hangul, CJK punctuation and fullwidth forms - the scripts the
    /// streaming model emits without inter-word spaces.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FFF,   // radicals, Kangxi
             0x3000...0x303F,   // CJK punctuation (。、「」)
             0x3040...0x30FF,   // hiragana, katakana
             0x3400...0x4DBF,   // CJK ext A
             0x4E00...0x9FFF,   // CJK unified
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility
             0xFE30...0xFE4F,   // CJK compatibility forms
             0xFF00...0xFFEF:   // fullwidth forms
            return true
        default:
            return false
        }
    }
}
