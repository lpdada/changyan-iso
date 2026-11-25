import SwiftUI
import AppGroup
import AICore

@MainActor
@Observable
final class KeyboardDictationState {
    // MARK: - Published state
    var isRecording: Bool
    var isSessionActive: Bool
    var transcriptionStatus: AppGroupCoordinator.TranscriptionStatus
    var errorMessage: String? {
        didSet {
            if errorMessage == nil && transcriptionStatus == .error {
                AppGroupCoordinator.shared.updateTranscriptionStatus(.idle)
            }
            if errorMessage != nil && transcriptionStatus == .error {
                autoDismissError()
            }
        }
    }

    // Audio level from main app recording (0.0 to 1.0)
    var currentAudioLevel: CGFloat = 0.0

    // MARK: - Keyboard Tab

    /// The active keyboard tab: `.keyboard` for normal typing, `.textProcessing` for rewrite mode.
    enum KeyboardTab: Int {
        case keyboard = 0
        case textProcessing = 1
        case recentNotes = 2
    }

    /// 拼音九宫格是否为当前输入模式。与 KeyboardKit 的语言布局并存：
    /// 开 = 显示 T9 九宫格，关 = 显示 KeyboardKit 键盘（英/法/德等）。
    /// 默认开（中文用户的默认输入面），选择持久化到本地 defaults。
    var isPinyinMode: Bool {
        didSet {
            AppGroupCoordinator.shared.clientDefaults
                .set(isPinyinMode, forKey: "vdPinyinModeEnabled")
        }
    }

    var activeTab: KeyboardTab = .keyboard {
        didSet {
            AppGroupCoordinator.shared.clientDefaults
                .set(activeTab.rawValue, forKey: "keyboardActiveTab")
        }
    }

    // MARK: - Text Processing (Rewrite)

    enum TextProcessingPhase: Equatable {
        case idle
        /// Recording a spoken rewrite instruction ("speak to edit").
        case recordingInstruction
        case sendingToApp
        case waitingForResult(modeName: String)
        case completed
        case error(String)
    }

    var textProcessingPhase: TextProcessingPhase = .idle

    /// Callback for when the main app returns a processed text result.
    var onTextProcessingResult: ((String) -> Void)?

    /// Callback for when the main app returns a text processing error.
    var onTextProcessingError: ((String) -> Void)?

    /// Callback for when the keyboard session expires during text processing.
    var onSessionExpired: (() -> Void)?

    // MARK: - VivaMode Manager
    var vivaModeManager = VivaModeManager()

    // Callback called when transcription text is ready to be pasted to user's input field. Called by KeyboardViewController
    var onTranscriptionReady: ((String) -> Void)?

    /// Set by `KeyboardViewController` when a transcription completes in a mode
    /// with Obsidian append enabled. `KeyboardCustomView` observes this and
    /// fires `openURL` via the SwiftUI environment (the only API that can open
    /// URLs from a keyboard extension), then clears it back to nil.
    var pendingObsidianURL: URL?

    // MARK: - Auto-dismiss
    private var errorDismissTask: Task<Void, Never>?

    // MARK: - Init
    init() {
        self.isRecording = AppGroupCoordinator.shared.isRecording
        self.isSessionActive = AppGroupCoordinator.shared.isKeyboardSessionActive
        self.transcriptionStatus = AppGroupCoordinator.shared.transcriptionStatus
        self.isPinyinMode = AppGroupCoordinator.shared.clientDefaults
            .object(forKey: "vdPinyinModeEnabled") as? Bool ?? true

        // Restore last active tab
        let savedTab = AppGroupCoordinator.shared.clientDefaults.integer(forKey: "keyboardActiveTab")
        self.activeTab = KeyboardTab(rawValue: savedTab) ?? .keyboard
    }

    // MARK: - UI Derivations
    enum UIState {
        case notReady,
             ready,
             recording,
             processing,
             error
    }

    var uiState: UIState {
        if isRecording { return .recording }
        
        switch transcriptionStatus {
        case .transcribing, .enhancing: return .processing
        case .error: return .error
        default: break
        }
        
        return isSessionActive ? .ready : .notReady
    }

    var micColor: Color {
        switch uiState {
        case .notReady: return .secondary
        case .ready: return .orange
        case .recording: return .red
        case .processing: return .primary
        case .error: return .orange
        }
    }

    // MARK: - Lifecycle

    /// 当前占着 coordinator 回调槽的那个实例（fork28）。
    ///
    /// `stop()` 是异步的（`Task { @MainActor }`）：旧键盘界面销毁时排队的
    /// 清理动作，可能落在新界面 `start()` 之后，把新实例刚装上的回调全部
    /// 抹掉。抹掉之后新键盘就聋了——点话筒照旧能发出开始录音（那是直接
    /// 调用 coordinator），主 App 也真的开始录，但录音态/转录结果再也传不
    /// 回来：界面不动、字也不插。只有它自己还是槽的主人时才允许清。
    private static weak var callbackOwner: KeyboardDictationState?

    func start() {
        // Refresh VivaModes when keyboard starts
        vivaModeManager.refreshVivaModes()

        Self.callbackOwner = self
        AppGroupCoordinator.shared.onRecordingStateChanged = { [weak self] state in
            self?.isRecording = state
        }
        AppGroupCoordinator.shared.onKeyboardSessionActivated = { [weak self] in
            self?.isSessionActive = true
        }
        AppGroupCoordinator.shared.onKeyboardSessionExpired = { [weak self] in
            self?.isSessionActive = false
            self?.onSessionExpired?()
        }
        AppGroupCoordinator.shared.onTranscriptionTranscribing = { [weak self] in
            self?.transcriptionStatus = .transcribing
            self?.advanceInstructionPhaseIfNeeded()
        }
        AppGroupCoordinator.shared.onTranscriptionEnhancing = { [weak self] in
            self?.transcriptionStatus = .enhancing
            self?.advanceInstructionPhaseIfNeeded()
        }
        AppGroupCoordinator.shared.onTranscriptionCompleted = { [weak self] transcription in
            self?.transcriptionStatus = .completed
            self?.onTranscriptionReady?(transcription)
        }
        AppGroupCoordinator.shared.onTranscriptionError = { [weak self] in
            self?.transcriptionStatus = .error
        }
        AppGroupCoordinator.shared.onTranscriptionCancelled = { [weak self] in
            self?.transcriptionStatus = .idle
        }
        AppGroupCoordinator.shared.onTranscriptionErrorMessage = { [weak self] message in
            self?.errorMessage = message
        }
        AppGroupCoordinator.shared.onAudioLevelUpdated = { [weak self] level in
            self?.currentAudioLevel = level
        }

        // Text processing callbacks (rewrite feature)
        AppGroupCoordinator.shared.onTextProcessingCompleted = { [weak self] text in
            self?.onTextProcessingResult?(text)
        }
        AppGroupCoordinator.shared.onTextProcessingError = { [weak self] message in
            self?.onTextProcessingError?(message)
        }
    }
    
    nonisolated func stop() {
        Task { @MainActor in
            // 已被更新的键盘实例接管时什么都不做：否则会把它的回调抹掉，
            // 让新键盘变成「能发指令、收不到状态」（fork28）。
            guard Self.callbackOwner === self else { return }
            Self.callbackOwner = nil
            AppGroupCoordinator.shared.onRecordingStateChanged = nil
            AppGroupCoordinator.shared.onKeyboardSessionActivated = nil
            AppGroupCoordinator.shared.onKeyboardSessionExpired = nil
            AppGroupCoordinator.shared.onTranscriptionTranscribing = nil
            AppGroupCoordinator.shared.onTranscriptionEnhancing = nil
            AppGroupCoordinator.shared.onTranscriptionCompleted = nil
            AppGroupCoordinator.shared.onTranscriptionError = nil
            AppGroupCoordinator.shared.onTranscriptionCancelled = nil
            AppGroupCoordinator.shared.onAudioLevelUpdated = nil
            AppGroupCoordinator.shared.onTextProcessingCompleted = nil
            AppGroupCoordinator.shared.onTextProcessingError = nil
            errorDismissTask?.cancel()
            errorDismissTask = nil
        }
    }

    /// 把 coordinator（桥模式下是主 App 的状态快照）里的真值同步进 UI 状态。
    ///
    /// 这个方法是「拉」的那条腿：Darwin 通知丢了、键盘进程被挂起过、
    /// 回调被旧实例清空过，只要键盘还看得见，下一次轮询就能把界面纠回来。
    /// 调用前应先 `await pollKeyboardState()` 让缓存是新值。
    func resyncFromCoordinator() {
        let coordinator = AppGroupCoordinator.shared
        let recording = coordinator.isRecording
        if isRecording != recording { isRecording = recording }
        let active = coordinator.isKeyboardSessionActive
        if isSessionActive != active { isSessionActive = active }
        let status = coordinator.transcriptionStatus
        if transcriptionStatus != status { transcriptionStatus = status }
        if currentAudioLevel != coordinator.currentAudioLevel {
            currentAudioLevel = coordinator.currentAudioLevel
        }
    }

    // MARK: - Actions
    func requestStartRecording() {
        if transcriptionStatus == .error {
            errorMessage = nil
            transcriptionStatus = .idle
            AppGroupCoordinator.shared.updateTranscriptionStatus(.idle)
        }

        if AppGroupCoordinator.shared.isKeyboardSessionActive {
            if vivaModeManager.selectedVivaMode.useClipboardContext {
                // Capture clipboard from keyboard context for AI processing
                // (keyboard has direct access to the active app's clipboard)
                AppGroupCoordinator.shared.setKeyboardClipboardContext(UIPasteboard.general.string)
            }
            AppGroupCoordinator.shared.requestStartRecording()

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.0))
                guard let self else { return }
                if !self.isRecording {
                    // 桥拉取单次超时就是 2 秒，1 秒时本地态可能还没跟上：
                    // 先拉一次快照对账，仍未录音才以协调器读到的会话态为准，
                    // 不再直接把会话打回未激活——慢拉取不应被误判成会话丢失，
                    // 否则下一次点话筒会走热麦流程而非开始录音，整场更难翻盘。
                    await AppGroupCoordinator.shared.reconcileRecordingState()
                    if !self.isRecording {
                        self.isSessionActive = AppGroupCoordinator.shared.isKeyboardSessionActive
                    }
                }
            }
        } else {
            self.isSessionActive = false
        }
    }
    
    func requestStopRecording() {
        AppGroupCoordinator.shared.requestStopRecording()
    }
    
    func requestCancelRecording() {
        AppGroupCoordinator.shared.requestCancelRecording()
    }

    /// Moves a spoken instruction out of its recording phase once the main app
    /// starts working on it.
    ///
    /// The instruction round trip rides the ordinary recording notifications, so
    /// these broadcasts are the only progress signal the keyboard gets. While one
    /// is in flight they drive the text processing UI, not the dictation UI.
    private func advanceInstructionPhaseIfNeeded() {
        guard textProcessingPhase == .recordingInstruction else { return }
        textProcessingPhase = .waitingForResult(modeName: vivaModeManager.selectedVivaMode.name)
    }

    // MARK: - Error Auto-dismiss
    private func autoDismissError() {
        errorDismissTask?.cancel()
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5.0))
            guard let self, !Task.isCancelled else { return }
            if self.transcriptionStatus == .error && self.errorMessage != nil {
                self.clearError()
            }
        }
    }

    private func clearError() {
        errorMessage = nil
        transcriptionStatus = .idle
        AppGroupCoordinator.shared.updateTranscriptionStatus(.idle)
        errorDismissTask?.cancel()
        errorDismissTask = nil
    }
}
