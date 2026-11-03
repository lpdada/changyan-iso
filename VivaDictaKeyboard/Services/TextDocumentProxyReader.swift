//
//  TextDocumentProxyReader.swift
//  VivaDictaKeyboard
//
//  Created by Anton Novoselov on 2026.03.21
//

import UIKit

/// Reads text from a host app's text field via `UITextDocumentProxy`.
///
/// 三条路，按可靠性排：
/// - **选中文本**：`selectedText` 直接给，最可靠。
/// - **光标前一段**：`documentContextBeforeInput` — 只保证“紧贴光标的那一段”。
///   The host app decides how much text to return（备忘录给得长，微信/Telegram
///   常常只给一两行）。
/// - **光标前全部**：``readWholeTextBeforeCursor(from:)`` — 用
///   `adjustTextPosition(byCharacterOffset:)` 一段段往左走到文首，再拼成全文。
///
/// 注意：“光标前一段”不等于“光标前全部”。长输入时宿主只给尾巴那一段，拿它
/// 去翻、再按它的字数往前删，表现就是“只翻了后面一小段、前面的原样留着”
/// （2026-11-03 报的那个 bug）。要整框，得走 ``readWholeTextBeforeCursor(from:)``。
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
    /// 只给“光标前一段”，要全文用 ``readWholeTextBeforeCursor(from:)``。
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

    // MARK: - 光标前全部文字

    /// 整框读取的三种结局。分开报，是因为三种该做的事不一样：
    /// 读到了就翻整框；“宿主不给”可以安全回落成只翻一段；
    /// “光标回不去”绝不能回落——那时按字数往前删会删错地方。
    enum WholeTextResult {
        /// 拿到光标前全部文字，光标已退回出发点。
        case whole(String)
        /// 宿主不配合（不认光标移动，或太长撞上限），光标没被留在半路，
        /// 调用方回落到“光标前一段”是安全的。
        case unavailable
        /// 走了一半退不回去：光标位置已不可信，这一单必须放弃。
        case cursorLost
    }

    /// 一次最多拼多少字（utf16）：再长也不适合一次发给模型。撞上上限就认输
    /// （返回 `.unavailable`），不翻一半，也不在错位置删字。
    static let maxWholeTextCharacters = 20_000

    /// 走位步数上限：宿主不认 `adjustTextPosition` 时每步都是空转，用它兜底。
    /// 正常宿主一段至少给几百字，2000 步够走十几万字。
    private static let maxWalkSteps = 2_000

    /// 光标前的全部文字；读完把光标原样退回原来的位置。
    ///
    /// 每步的走距取宿主这次给的那一段的 utf16 长度：走完这一段，下一段的末尾
    /// 正好接上这一段的开头，所以无论宿主一段给多少，拼出来都是连续的全文，
    /// 不用做重叠合并。走完再按记录的长度原路退回，调用方按字数往前删时，
    /// 删掉的正好是这段文字。
    ///
    /// 长度一律按 utf16 计：宿主按 NSRange（utf16）算位置，用 Character 数会在
    /// emoji、组合字符处走偏。
    static func readWholeTextBeforeCursor(from proxy: UITextDocumentProxy) -> WholeTextResult {
        let start = proxy.documentContextBeforeInput ?? ""
        // 光标已在文首（或宿主根本没给内容）：没有可读的，交给调用方判空。
        guard !start.isEmpty else { return .whole("") }

        var chunks: [String] = []
        var lengths: [Int] = []
        var total = 0
        var chunk = start

        while !chunk.isEmpty, lengths.count < maxWalkSteps, total < maxWholeTextCharacters {
            let length = chunk.utf16.count
            proxy.adjustTextPosition(byCharacterOffset: -length)
            let moved = proxy.documentContextBeforeInput ?? ""

            // 挪完内容没变 = 宿主没动光标（或这段文本周期性重复）。再走只会
            // 原地打转，收工交给下面的退回判定。
            guard moved != chunk else { break }

            chunks.append(chunk)
            lengths.append(length)
            total += length
            chunk = moved
        }

        // 只有确实走到文首，手里这份才算“整框”；中途停下的一律当读不全。
        let reachedStart = chunk.isEmpty

        // 无论读没读全，光标都必须回得去：回不去就不能让调用方按字数往前删。
        guard restore(proxy, lengths: lengths, start: start) else { return .cursorLost }
        guard reachedStart, !chunks.isEmpty else { return .unavailable }

        return .whole(chunks.reversed().joined())
    }

    /// 按走位记录原路退回光标，并用“光标前那一段是否和出发时一模一样”校验。
    ///
    /// 校验比逐步检查可靠：哪一步宿主少走或多走，最后一段对上才算真回到位。
    private static func restore(_ proxy: UITextDocumentProxy, lengths: [Int], start: String) -> Bool {
        for length in lengths.reversed() {
            proxy.adjustTextPosition(byCharacterOffset: length)
        }
        return (proxy.documentContextBeforeInput ?? "") == start
    }
}
