// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation

/// The socket operations one self-hosted dictation needs.
///
/// `StreamingWebSocketClient` is the real conformer; a test double plays the
/// server without a socket, so the end-of-audio and disconnect behaviour below
/// is exercised rather than assumed.
protocol StreamingServerConnection: Actor {
    func connect(
        serverURL: URL,
        apiKey: String,
        language: String,
        maxSpeakers: Int
    ) -> AsyncStream<StreamingServerEvent>

    func sendAudioChunk(_ data: Data)

    func sendEnd()

    func disconnect()
}

/// One dictation over the self-hosted streaming endpoint - the same socket the
/// meeting screen uses (`wss://<host>/v1/stream`), driven by `StreamingAudioCapture`
/// through `RealtimeDictationCoordinator`.
///
/// Why this exists: the upload path can only start once the user stops talking.
/// Here the PCM goes out while they speak, so at `finish()` the server has
/// normally already emitted the finals and only the tail is outstanding.
///
/// Accuracy rules, all of them mechanical rather than asserted:
///
/// - The server's offline correction pass (`offline_correction: true` in the auth
///   frame) returns the authoritative text for a segment; the corrected final
///   wins over any other frame for that id.
/// - Every failure mode throws: a transport drop, a server `error` frame, a
///   missing `session_end`, or no text at all. `finish()` never returns a
///   truncated transcript as a success - the caller falls back to uploading the
///   WAV that `StreamingAudioCapture` wrote alongside the socket.
actor SelfHostedRealtimeSession: RealtimeDictationSession {
    typealias SessionError = RealtimeDictationSessionError

    /// How long `finish()` waits for `session_end` after the end-of-audio frame.
    /// The offline correction runs on the server, so the finals can trail the
    /// last spoken word; a session that never confirms is treated as failed
    /// rather than as a short transcript.
    static let defaultFinalizeTimeout: Duration = .seconds(10)

    /// Forwarded as `max_speakers` in the auth frame, which the contract
    /// requires. Dictation has one speaker and ignores the labels; the value is
    /// the one the meeting path already proves the server accepts.
    static let authMaxSpeakers = 10

    private let serverURL: URL
    private let connection: any StreamingServerConnection
    private let finalizeTimeout: Duration

    private var transcript = SelfHostedStreamingTranscript()
    private var isRunning = false
    private var failureMessage: String?
    /// Set only by a `session_end` frame: the one signal that the server has
    /// committed to the whole recording.
    private var didConfirmEnd = false
    private var receiveTask: Task<Void, Never>?

    init(
        serverURL: URL,
        connection: any StreamingServerConnection,
        finalizeTimeout: Duration = SelfHostedRealtimeSession.defaultFinalizeTimeout
    ) {
        self.serverURL = serverURL
        self.connection = connection
        self.finalizeTimeout = finalizeTimeout
    }

    /// Text captured so far. Safe to read at any point; nothing in this round
    /// displays it mid-recording.
    var currentText: String {
        transcript.text
    }

    func start(apiKey: String, languageHints: [String], vocabularyTerms: [String]) async {
        guard !isRunning else { return }
        isRunning = true

        // The streaming contract has no vocabulary field (the upload endpoint
        // takes one), so the terms are accepted for the shared protocol and not
        // sent. Nothing is silently mangled either way.
        _ = vocabularyTerms

        let stream = await connection.connect(
            serverURL: serverURL,
            apiKey: apiKey,
            language: Self.language(hints: languageHints),
            maxSpeakers: Self.authMaxSpeakers
        )

        receiveTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
            await self?.markStreamEnded()
        }
    }

    func send(_ pcmChunk: Data) async {
        guard isRunning, failureMessage == nil else { return }
        await connection.sendAudioChunk(pcmChunk)
    }

    /// Signals end-of-audio, waits for the server's confirmation, and returns
    /// the transcript.
    ///
    /// Throws on every incomplete outcome, so `RealtimeDictationCoordinator`'s
    /// caller uploads the recorded WAV instead of saving a partial text.
    func finish() async throws -> String {
        guard isRunning else { throw SessionError.producedNoText }

        await connection.sendEnd()

        let deadline = ContinuousClock.now.advanced(by: finalizeTimeout)
        while !didConfirmEnd, failureMessage == nil, ContinuousClock.now < deadline {
            // A cancelled task makes `Task.sleep` throw immediately, and `try?`
            // would swallow it into a full-speed spin until the deadline.
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let failure = failureMessage
        let confirmed = didConfirmEnd

        await teardown()

        if let failure {
            throw SessionError.transportFailed(failure)
        }

        // No `session_end`: the socket closed or went quiet before the server
        // committed to the recording, so the tail may be missing.
        if !confirmed {
            throw SessionError.transportFailed("timed out waiting for session_end")
        }

        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SessionError.producedNoText }
        return text
    }

    /// Aborts without waiting - used when the user cancels the recording.
    func cancel() async {
        await teardown()
    }

    // MARK: - Private

    /// The contract's `language` field takes one code, or `auto`. An unsupported
    /// code is passed through rather than quietly rewritten: the server answers
    /// with `streaming_unsupported_language`, this fails, and the caller uploads
    /// the file - which is the honest outcome for a language the streaming model
    /// does not serve.
    static func language(hints: [String]) -> String {
        guard let first = hints.first, !first.isEmpty else { return "auto" }
        return first
    }

    private func handle(_ event: StreamingServerEvent) {
        switch event {
        case .ready:
            break
        case .interimSegment(let segmentID, let text, _, _, _):
            transcript.applyInterim(segmentID: segmentID, text: text)
        case .finalSegment(let segmentID, let text, _, _, _, _, _, let corrected):
            transcript.applyFinal(segmentID: segmentID, text: text, corrected: corrected)
        case .speakerUpdated:
            // Dictation has no diarization; the labels are intentionally dropped.
            break
        case .failed(let error):
            failureMessage = error.message
        case .sessionEnded:
            didConfirmEnd = true
        }
    }

    /// The event stream is over: `session_end`, a disconnect, or a failure.
    /// A stream that ends without `session_end` is treated as a disconnect -
    /// the server never said it was done, so the text may be short.
    private func markStreamEnded() {
        guard !didConfirmEnd else { return }
        if failureMessage == nil {
            failureMessage = "stream ended before the server confirmed the transcript"
        }
    }

    private func teardown() async {
        isRunning = false
        receiveTask?.cancel()
        receiveTask = nil
        await connection.disconnect()
    }
}
