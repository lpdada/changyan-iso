//
//  KeyboardTextProcessor.swift
//  VivaDictaKeyboard
//
//  Created by Anton Novoselov on 2026.03.21
//

import UIKit
import AppGroup
import os
import AICore

/// Orchestrates the text processing pipeline from the keyboard extension:
/// 1. Read text from host text field via `UITextDocumentProxy`
///    (selected text, or text before cursor if nothing selected)
/// 2. Send to main app for AI processing via `AppGroupCoordinator`
/// 3. Wait for result
/// 4. Replace the original text with the processed result
///
/// Two ways in, sharing steps 1, 3 and 4:
/// - ``processText(proxy:mode:presetId:dictationState:)`` applies a preset the
///   user tapped.
/// - ``processTextWithSpokenInstruction(proxy:mode:dictationState:)`` records an
///   ad-hoc spoken instruction first ("make this more formal") and applies that.
@MainActor
final class KeyboardTextProcessor {

    private let logger = Logger(category: .keyboardExtension)
    private var currentTask: Task<Void, Never>?
    private var resultContinuation: CheckedContinuation<String, Error>?
    private var isProcessing = false
    /// True while the main app is recording a spoken instruction for us, so
    /// ``cancel()`` knows it also has to stop that recording.
    private var isRecordingInstruction = false

    /// Processes text in the host text field using the specified mode and optional preset.
    ///
    /// If text is selected, processes the selection. Otherwise, processes
    /// `documentContextBeforeInput` (text before cursor).
    func processText(
        proxy: UITextDocumentProxy,
        mode: VivaMode,
        presetId: String? = nil,
        dictationState: KeyboardDictationState
    ) {
        // Prevent double invocation
        guard !isProcessing else {
            logger.logInfo("📝 [TextProcessor] Ignoring duplicate invocation — already processing")
            return
        }

        // GPU-backed on-device LLMs (Gemma/LiteRT, MLX) run on the Metal GPU, which
        // iOS blocks while the app is backgrounded - and the keyboard always runs
        // with the main app backgrounded. The doomed round-trip would otherwise
        // hang or crash the app, so fail fast here with an actionable message.
        // CoreML models (ANE) are exempt - they DO work backgrounded. Apple FM
        // (out-of-process) and cloud providers also work from the keyboard.
        if mode.aiProvider == .local, !AIProvider.localModelRunsOnNeuralEngine(mode.aiModel) {
            logger.logInfo("📝 [TextProcessor] GPU on-device mode '\(mode.name)' unavailable from keyboard (GPU blocked in background)")
            HapticManager.error()
            dictationState.textProcessingPhase = .error("This on-device model runs on the GPU and needs the Changyan app open. Use a CoreML model, Apple Foundation Model, or a cloud model from the keyboard.")
            autoDismissError(dictationState: dictationState)
            return
        }

        // Cancel any stale state
        cancel()

        isProcessing = true
        currentTask = Task {
            defer { isProcessing = false }
            do {
                try await performProcessing(proxy: proxy, mode: mode, presetId: presetId, dictationState: dictationState)
            } catch is CancellationError {
                dictationState.textProcessingPhase = .idle
            } catch {
                HapticManager.error()
                dictationState.textProcessingPhase = .error(error.localizedDescription)
                autoDismissError(dictationState: dictationState)
            }
        }
    }

    /// 把光标前全部内容翻成日语，并原位替换（2026-10-30 起不再只翻最后一句，
    /// 2026-11-03 起不再只翻宿主给的那一段，改走整框读取）。
    ///
    /// 与 ``processText(proxy:mode:presetId:dictationState:)`` 的区别只剩走 AppGroup
    /// 通知等主 App 回结果；读取范围与那边一致：选中文本优先，否则光标前全部文本。
    func translateCurrentSentence(
        proxy: UITextDocumentProxy,
        mode: VivaMode,
        presetId: String = "translate_ja",
        dictationState: KeyboardDictationState
    ) {
        guard !isProcessing else {
            logger.logInfo("📝 [TextProcessor] Ignoring duplicate translate — already processing")
            return
        }

        // 与 processText 相同的 GPU 限制：键盘在前台后台时 Metal 被系统封住
        if mode.aiProvider == .local, !AIProvider.localModelRunsOnNeuralEngine(mode.aiModel) {
            HapticManager.error()
            dictationState.textProcessingPhase = .error("This on-device model runs on the GPU and needs the Changyan app open. Use a CoreML model, Apple Foundation Model, or a cloud model from the keyboard.")
            autoDismissError(dictationState: dictationState)
            return
        }

        cancel()

        isProcessing = true
        currentTask = Task {
            defer { isProcessing = false }
            do {
                // 读文本放在 Task 里：整框读取要等宿主把光标挪动后的内容递上来，
                // 不能同步阻塞这次点按。
                guard let target = try await readTranslateTarget(from: proxy, dictationState: dictationState) else { return }

                dictationState.textProcessingPhase = .sendingToApp

                let translated = try await awaitResult(dictationState: dictationState) {
                    AppGroupCoordinator.shared.requestTextProcessing(
                        text: target.text,
                        modeName: mode.name,
                        presetId: presetId
                    )
                    dictationState.textProcessingPhase = .waitingForResult(modeName: sourceLabel(for: target))
                }

                try Task.checkCancellation()
                replace(target: target, with: translated, in: proxy, dictationState: dictationState)
            } catch is CancellationError {
                dictationState.textProcessingPhase = .idle
            } catch {
                HapticManager.error()
                dictationState.textProcessingPhase = .error(error.localizedDescription)
                autoDismissError(dictationState: dictationState)
            }
        }
    }

    /// 键盘端直译（九宫格星星「译」专用）：不走“发通知等主 App 回结果”，
    /// 直接拿 App Group 快照里的模型和 Key 调接口。主 App 没在后台活着
    /// 也能翻；代价是键盘联网要求“允许完全访问”，没开时请求失败会进
    /// error 分支给一句人话提示，不再静默转圈。目标固定日语。
    /// 翻译目标是光标前全部内容（2026-10-30 起不再只翻最后一句；2026-11-03
    /// 起不再只翻宿主给的那一段，改走整框读取）；选中文本时只翻选中的部分。
    func translateCurrentTextDirectly(
        proxy: UITextDocumentProxy,
        dictationState: KeyboardDictationState
    ) {
        guard !isProcessing else {
            logger.logInfo("📝 [TextProcessor] Ignoring duplicate direct translate — already processing")
            return
        }

        cancel()

        isProcessing = true
        currentTask = Task {
            defer { isProcessing = false }
            do {
                // 读文本放在 Task 里：整框读取要等宿主把光标挪动后的内容递上来
                // （见 TextDocumentProxyReader.settleMilliseconds），不能同步阻塞点按。
                guard let target = try await readTranslateTarget(from: proxy, dictationState: dictationState) else { return }

                guard target.text.count >= 2 else {
                    HapticManager.error()
                    dictationState.textProcessingPhase = .error("内容太短，没什么可翻的")
                    autoDismissError(dictationState: dictationState)
                    return
                }

                // 桥模式：点之前先拉一次配置快照（主 App 在就刷新轮换后的 Key，
                // 不在就瞬间失败、继续用旧缓存；拉取从不删旧缓存，见
                // AppGroupCoordinator.pullBridgeConfigIntoCache）。
                if LocalBridge.isEnabled {
                    await AppGroupCoordinator.shared.pullBridgeConfigIntoCache()
                    try Task.checkCancellation()
                }

                guard SharedAIConfig.isConfigured else {
                    HapticManager.error()
                    dictationState.textProcessingPhase = .error(SharedAIConfig.unavailableHint)
                    autoDismissError(dictationState: dictationState)
                    return
                }

                dictationState.textProcessingPhase = .waitingForResult(
                    modeName: sourceLabel(for: target)
                )

                guard let translated = await SentenceTranslator.shared.translate(target.text) else {
                    throw TextProcessingError.processingFailed("翻译失败：请检查网络、完全访问权限与模型配置")
                }

                try Task.checkCancellation()
                replace(target: target, with: translated, in: proxy, dictationState: dictationState)
            } catch is CancellationError {
                dictationState.textProcessingPhase = .idle
            } catch {
                HapticManager.error()
                dictationState.textProcessingPhase = .error(error.localizedDescription)
                autoDismissError(dictationState: dictationState)
            }
        }
    }

    /// 翻译目标：选中文本优先（翻选中的全部），否则光标前全部文本。
    ///
    /// 2026-10-30 前这里只取“最后一句”（按 。！？ 等句末标点切分），之后改成
    /// “光标前一段”。但 `documentContextBeforeInput` 给多长由宿主定，长输入时
    /// 只有尾巴那一段，于是长文本仍只翻后面一小截（2026-11-03 再报）。现在先走
    /// ``TextDocumentProxyReader/readWholeTextBeforeCursor(from:)`` 把整段走完，
    /// 只有宿主不配合移动光标时才回落到“光标前一段”。
    ///
    /// 替换时按目标字数往前删，字数必须与原文一致，因此这里不 trim 原文（只用
    /// trim 判空），避免删错范围；整框读成功时光标已退回原处，删的正好是整框。
    private func readTranslateTarget(
        from proxy: UITextDocumentProxy,
        dictationState: KeyboardDictationState
    ) async throws -> Target? {
        // 框选优先：用户框了哪段就翻哪段，不动框外。
        if let selected = proxy.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.logInfo("📝 [TextProcessor] Translating selection (\(selected.count) chars)")
            return Target(text: selected, isSelection: true, source: .selection)
        }

        // 整框要挪光标、等宿主回内容，可能在点上之后还要等一会儿，先给个反馈。
        dictationState.textProcessingPhase = .waitingForResult(modeName: "读取整段")

        // 整框：光标前全部文字（宿主默认只给紧贴光标的一段）。
        switch await TextDocumentProxyReader.readWholeTextBeforeCursor(from: proxy) {
        case .whole(let whole):
            guard !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return noTextError(dictationState: dictationState)
            }
            logger.logInfo("📝 [TextProcessor] Translating whole text before cursor (\(whole.count) chars)")
            return Target(text: whole, isSelection: false, source: .wholeDocument)
        case .unavailable(let failure):
            switch failure {
            case .cancelled:
                // 用户点了取消：光标已退回，什么都不做。
                dictationState.textProcessingPhase = .idle
                return nil
            case .hostIgnoredCursorMove, .tooLong:
                logger.logInfo("📝 [TextProcessor] Whole-text walk unavailable (\(failure.rawValue)) — falling back to the host's before-cursor chunk")
            }
        case .cursorLost:
            // 光标被留在半路：这时不能回落（会按字数删错地方），直接放弃这一单。
            HapticManager.error()
            dictationState.textProcessingPhase = .error("没法定位光标，这次翻译已取消：点一下输入框再试")
            autoDismissError(dictationState: dictationState)
            return nil
        }

        // 回落：宿主不认光标移动，读到的“光标前一段”就是这次能拿到的全部。
        // readWholeTextBeforeCursor 已把光标退回原位，所以这里读到的仍是原来位置那一段。
        switch TextDocumentProxyReader.readText(from: proxy) {
        case .selectedText(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return noTextError(dictationState: dictationState)
            }
            return Target(text: text, isSelection: true, source: .selection)
        case .textBeforeCursor(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return noTextError(dictationState: dictationState)
            }
            logger.logInfo("📝 [TextProcessor] Translating host chunk from before the cursor (\(text.count) chars)")
            return Target(text: text, isSelection: false, source: .hostChunk)
        case .empty:
            return noTextError(dictationState: dictationState)
        }
    }

    /// 「处理中」浮层上显示这次到底翻了多少字。整段读取可能被宿主挡回来，
    /// 字数就是「只翻了一段」最直接的证据——用户不用连电脑看日志。
    private func sourceLabel(for target: Target) -> String {
        switch target.source {
        case .selection: "选中 \(target.text.count) 字"
        case .wholeDocument: "整段 \(target.text.count) 字"
        case .hostChunk: "仅 \(target.text.count) 字·宿主没给整段"
        }
    }

    private func noTextError(dictationState: KeyboardDictationState) -> Target? {
        HapticManager.error()
        dictationState.textProcessingPhase = .error("没有可翻译的内容")
        autoDismissError(dictationState: dictationState)
        return nil
    }

    /// Records a spoken instruction and applies it to the host text field.
    ///
    /// Same read/replace path as ``processText(proxy:mode:presetId:dictationState:)``;
    /// the instruction is dictated instead of tapped. The target text is captured
    /// and parked *before* recording starts, so what gets rewritten is what was
    /// selected when the user reached for the mic.
    func processTextWithSpokenInstruction(
        proxy: UITextDocumentProxy,
        mode: VivaMode,
        dictationState: KeyboardDictationState
    ) {
        guard !isProcessing else {
            logger.logInfo("🗣️ [TextProcessor] Ignoring duplicate invocation — already processing")
            return
        }

        guard dictationState.isSessionActive else {
            HapticManager.error()
            dictationState.textProcessingPhase = .error("Open Changyan to use voice instructions.")
            autoDismissError(dictationState: dictationState)
            return
        }

        guard let target = readTarget(from: proxy, dictationState: dictationState) else { return }

        cancel()

        isProcessing = true
        isRecordingInstruction = true
        currentTask = Task {
            defer {
                isProcessing = false
                isRecordingInstruction = false
            }
            do {
                dictationState.textProcessingPhase = .recordingInstruction
                HapticManager.mediumImpact()

                let processedText = try await awaitResult(dictationState: dictationState) {
                    AppGroupCoordinator.shared.requestVoiceInstructionRecording(
                        targetText: target.text,
                        modeName: mode.name
                    )
                }

                try Task.checkCancellation()
                replace(target: target, with: processedText, in: proxy, dictationState: dictationState)
            } catch is CancellationError {
                dictationState.textProcessingPhase = .idle
            } catch {
                HapticManager.error()
                dictationState.textProcessingPhase = .error(error.localizedDescription)
                autoDismissError(dictationState: dictationState)
            }
        }
    }

    /// Cancels the current text processing operation.
    func cancel() {
        if isRecordingInstruction {
            // The main app may be mid-recording, or may not have picked the
            // request up at all. Undo both, or the next ordinary dictation gets
            // mistaken for an instruction.
            AppGroupCoordinator.shared.requestCancelRecording()
            AppGroupCoordinator.shared.clearPendingVoiceInstruction()
            isRecordingInstruction = false
        }
        resultContinuation?.resume(throwing: CancellationError())
        resultContinuation = nil
        currentTask?.cancel()
        currentTask = nil
        isProcessing = false
    }

    private func performProcessing(
        proxy: UITextDocumentProxy,
        mode: VivaMode,
        presetId: String? = nil,
        dictationState: KeyboardDictationState
    ) async throws {
        // Phase 1: Read text
        guard let target = readTarget(from: proxy, dictationState: dictationState) else { return }

        try Task.checkCancellation()

        // Phase 2: Send to main app
        dictationState.textProcessingPhase = .sendingToApp
        logger.logInfo("📝 [TextProcessor] Sending to AI with mode: \(mode.name), preset: \(presetId ?? "nil"), text (\(target.text.count) chars): \(target.text)")

        let processedText = try await awaitResult(dictationState: dictationState) {
            AppGroupCoordinator.shared.requestTextProcessing(
                text: target.text,
                modeName: mode.name,
                presetId: presetId
            )
            dictationState.textProcessingPhase = .waitingForResult(modeName: mode.name)
        }

        try Task.checkCancellation()

        // Phases 3 and 4
        replace(target: target, with: processedText, in: proxy, dictationState: dictationState)
    }

    // MARK: - Shared Steps

    /// What the AI result will replace: the user's selection, or the chunk of
    /// text before the cursor when nothing is selected.
    private struct Target {
        let text: String
        let isSelection: Bool
        /// 这段文字是从哪来的，只用来在「处理中」浮层上标字数。
        var source: TargetSource = .hostChunk
    }

    /// 取到的文字从哪来：框选的、整框读到的、还是宿主只给了一段。
    private enum TargetSource {
        case selection
        case wholeDocument
        case hostChunk
    }

    /// Phase 1 - reads the text to rewrite, surfacing the empty case as an error.
    private func readTarget(
        from proxy: UITextDocumentProxy,
        dictationState: KeyboardDictationState
    ) -> Target? {
        switch TextDocumentProxyReader.readText(from: proxy) {
        case .selectedText(let text):
            logger.logInfo("📝 [TextProcessor] Selected text read (\(text.count) chars): \(text)")
            return Target(text: text, isSelection: true)
        case .textBeforeCursor(let text):
            logger.logInfo("📝 [TextProcessor] Text before cursor read (\(text.count) chars): \(text)")
            return Target(text: text, isSelection: false)
        case .empty:
            logger.logInfo("📝 [TextProcessor] No text found")
            dictationState.textProcessingPhase = .error("没有可处理的文本")
            autoDismissError(dictationState: dictationState)
            return nil
        }
    }

    /// Phase 2 - runs `request` and suspends until the main app answers on the
    /// text processing channel, or the keyboard session goes away.
    private func awaitResult(
        dictationState: KeyboardDictationState,
        request: @escaping () -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.resultContinuation = continuation

            dictationState.onTextProcessingResult = { [weak self] result in
                if result.isEmpty {
                    self?.logger.logInfo("📝 [TextProcessor] Received empty result — treating as error")
                    self?.resultContinuation?.resume(throwing: TextProcessingError.processingFailed("AI 返回了空结果"))
                } else {
                    self?.resultContinuation?.resume(returning: result)
                }
                self?.resultContinuation = nil
            }

            dictationState.onTextProcessingError = { [weak self] message in
                self?.resultContinuation?.resume(throwing: TextProcessingError.processingFailed(message))
                self?.resultContinuation = nil
            }

            // Session expiry = main app went away
            dictationState.onSessionExpired = { [weak self] in
                self?.logger.logInfo("📝 [TextProcessor] Session expired during text processing")
                self?.resultContinuation?.resume(throwing: TextProcessingError.processingFailed("Session expired. Open Changyan and try again."))
                self?.resultContinuation = nil
            }

            // 超时：Darwin 通知唤不醒已杀掉的主 App——主 App 没在后台活着时，
            // 请求永远没人接，之前这里会一直停在“Processing: 畅言...”不动。
            // 60 秒没回音就主动报错，告诉用户先打开主 App 再点译；已先拿到
            // 结果时 continuation 已是 nil，这支 Task 是空转，不会重复 resume。
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self, let continuation = self.resultContinuation else { return }
                self.resultContinuation = nil
                self.logger.logInfo("📝 [TextProcessor] Text processing timed out — main app did not answer")
                continuation.resume(throwing: TextProcessingError.processingFailed("主 App 长时间没有响应：请先打开畅言 App，让它留在后台，再点译"))
            }

            request()
        }
    }

    /// Phases 3 and 4 - writes the result back over the original text and settles the UI.
    private func replace(
        target: Target,
        with processedText: String,
        in proxy: UITextDocumentProxy,
        dictationState: KeyboardDictationState
    ) {
        logger.logInfo("📝 [TextProcessor] AI result received (\(processedText.count) chars): \(processedText)")

        if target.isSelection {
            logger.logInfo("📝 [TextProcessor] Replacing selected text")
            TextDocumentProxyWriter.replaceSelectedText(in: proxy, with: processedText)
        } else {
            logger.logInfo("📝 [TextProcessor] Replacing \(target.text.count) chars before cursor")
            TextDocumentProxyWriter.replaceTextBeforeCursor(in: proxy, charCount: target.text.count, with: processedText)
        }

        HapticManager.heartbeat()
        AppGroupCoordinator.shared.recordKeyboardSuccessfulUse()
        dictationState.textProcessingPhase = .completed

        Task {
            try? await Task.sleep(for: .seconds(1))
            if dictationState.textProcessingPhase == .completed {
                dictationState.textProcessingPhase = .idle
            }
        }
    }

    private func autoDismissError(dictationState: KeyboardDictationState) {
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .error = dictationState.textProcessingPhase {
                dictationState.textProcessingPhase = .idle
            }
        }
    }

    enum TextProcessingError: LocalizedError {
        case processingFailed(String)

        var errorDescription: String? {
            switch self {
            case .processingFailed(let message): message
            }
        }
    }
}
