//
//  TextDocumentProxyReader.swift
//  VivaDictaKeyboard
//
//  Created by Anton Novoselov on 2026.03.21
//

import UIKit

/// Reads text from a host app's text field via `UITextDocumentProxy`.
///
/// Two modes:
/// - **Selected text**: Returns `selectedText` directly — most reliable.
/// - **Text before cursor**: Returns `documentContextBeforeInput` — the chunk
///   of text before the current cursor position. The host app decides how much
///   text to return (typically a large chunk, but varies by app).
///
/// 注意：上面那段“光标前一段”不等于“输入框全部文字”。长输入时宿主只给
/// 尾巴一段，拿它去翻、按它去删，结果就是 2026-11-03 报的“只翻后面一小段，
/// 前面原样留着”。要整框，必须用下面的 `readFullDocument` 分段走完。
@MainActor
final class TextDocumentProxyReader {

    enum ReadResult {
        /// User explicitly selected text.
        case selectedText(String)
        /// Text before cursor (no explicit selection).
        case textBeforeCursor(String)
        /// No text available.
        case empty
    }

    /// Reads text from the host text field.
    ///
    /// If text is selected, returns the selection. Otherwise, returns whatever
    /// `documentContextBeforeInput` provides at the current cursor position.
    static func readText(from proxy: UITextDocumentProxy) -> ReadResult {
        // Prefer explicit selection
        if let selected = proxy.selectedText, !selected.isEmpty {
            return .selectedText(selected)
        }

        // Fall back to text before cursor
        if let before = proxy.documentContextBeforeInput, !before.isEmpty {
            return .textBeforeCursor(before)
        }

        return .empty
    }

    /// 输入框全部文字：先一段一段往左走到文首，再从文首一段一段往右读到
    /// 文末拼起来。每段长度就是宿主这次给的段长——走完一段，下一段的开头
    /// 正好接上一段的末尾，所以无论宿主一段给多少，拼出来都是全文。
    ///
    /// 成功时光标停在文末，正好接“删全文、插译文”的替换；失败时返回 nil，
    /// 并且光标已复原到原来位置，调用方回落到旧的“光标前一段”逻辑——
    /// 翻不全也比在错误位置删一段强。
    ///
    /// 每步移动后都要验一次：往左挪过一段 C，挪成功的话光标后的文本必然
    /// 以 C 开头（宿主把段截断时，C 以这段开头）；往右同理。验不过说明
    /// 宿主根本没移动光标，继续走只会原地打转，直接失败复原。
    /// 光标偏移按 utf16 算：宿主文本系统按 NSRange（utf16）计位置，按 Swift
    /// 字符数算会在 emoji 处走偏。
    static func readFullDocument(from proxy: UITextDocumentProxy) -> String? {
        // displacement：相对原来光标位置的净偏移（utf16 单位），复原用 -displacement。
        // 只有验过成功的移动才计入，验失败的那步不算——因为它根本没动。
        var displacement = 0

        // Phase 1：走到文首。
        var steps = 0
        while steps < 1000 {
            guard let chunk = proxy.documentContextBeforeInput, !chunk.isEmpty else { break }
            let move = -chunk.utf16.count
            proxy.adjustTextPosition(byCharacterOffset: move)
            // 两道验：光标前的段必须变了（没变就是宿主没动光标，周期性
            // 重复文本也可能撞上，那就宁可失败回落，也不硬拼出一段错文），
            // 且光标后的段要以这段开头。
            let newBefore = proxy.documentContextBeforeInput
            guard newBefore != chunk,
                  movedLeftPast(chunk, after: proxy.documentContextAfterInput) else {
                proxy.adjustTextPosition(byCharacterOffset: -displacement)
                return nil
            }
            displacement += move
            steps += 1
        }
        guard proxy.documentContextBeforeInput?.isEmpty == true else {
            // 步数封顶还没到文首：别硬说这是全文，复原后失败。
            proxy.adjustTextPosition(byCharacterOffset: -displacement)
            return nil
        }

        // Phase 2：从文首读到文末。
        var full = ""
        steps = 0
        while steps < 1000 {
            guard let chunk = proxy.documentContextAfterInput, !chunk.isEmpty else { break }
            full += chunk
            if full.count > 50_000 {
                // 译文请求本身也装不下更长的，复原后失败，不翻一半。
                proxy.adjustTextPosition(byCharacterOffset: -displacement)
                return nil
            }
            let move = chunk.utf16.count
            proxy.adjustTextPosition(byCharacterOffset: move)
            // 同左：光标后的段必须变了，且光标前的段要以这段结尾。
            let newAfter = proxy.documentContextAfterInput
            guard newAfter != chunk,
                  movedRightPast(chunk, before: proxy.documentContextBeforeInput) else {
                proxy.adjustTextPosition(byCharacterOffset: -displacement)
                return nil
            }
            displacement += move
            steps += 1
        }
        guard proxy.documentContextAfterInput?.isEmpty == true else {
            proxy.adjustTextPosition(byCharacterOffset: -displacement)
            return nil
        }
        return full
    }

    /// 往左挪过一段 chunk 之后，光标后的文本应以 chunk 开头；
    /// 宿主把段截断时，chunk 以这段开头。两者都不满足就是没挪动。
    private static func movedLeftPast(_ chunk: String, after: String?) -> Bool {
        guard let after, !after.isEmpty else { return false }
        return chunk.hasPrefix(after) || after.hasPrefix(chunk)
    }

    /// 往右挪过一段 chunk 之后，光标前的文本应以 chunk 结尾；
    /// 宿主把段截断时，chunk 以这段结尾。两者都不满足就是没挪动。
    private static func movedRightPast(_ chunk: String, before: String?) -> Bool {
        guard let before, !before.isEmpty else { return false }
        return chunk.hasSuffix(before) || before.hasSuffix(chunk)
    }
}
