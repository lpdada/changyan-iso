import Foundation
import os

/// URLSessionWebSocketTask client for the self-hosted streaming ASR
/// endpoint. It speaks exactly one wire contract (see `Event`); every
/// field name below matches the contract, including the snake_case
/// names, which are mapped through explicit `CodingKeys`.
///
/// Flow: `connect` opens the socket and sends the `auth` frame as the
/// first text frame, then starts the receive loop. The caller owns the
/// ready wait: the first `Event` is normally `.ready`, and an `error`
/// frame before it surfaces as `.failed` instead of being swallowed.
/// Audio goes out as binary frames; `sendEnd` sends the `{"type":"end"}`
/// frame. An `error` frame mid-session is yielded as `.failed` but does
/// NOT close the stream (the server may keep going); a transport failure
/// or `session_end` does finish the stream.
actor StreamingWebSocketClient {
    /// The events are declared in `StreamingServerProtocol.swift`, which both
    /// this client and the dictation session compile against.
    typealias Event = StreamingServerEvent

    private let logger = Logger(category: .selfHostedTranslation)
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?

    /// Opens the socket for `serverURL` (its scheme is converted
    /// http->ws / https->wss and `/v1/stream` is appended; the host is
    /// never hard-coded) and sends the auth frame. Returns the event
    /// stream; the caller waits for `.ready` on it.
    ///
    /// - Parameters:
    ///   - language: BCP-style code the server expects, e.g. "zh".
    ///   - maxSpeakers: forwarded as `max_speakers` in the auth frame.
    func connect(
        serverURL: URL,
        apiKey: String,
        language: String,
        maxSpeakers: Int
    ) -> AsyncStream<Event> {
        disconnect()

        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation

        guard let url = Self.streamURL(from: serverURL) else {
            continuation.yield(.failed(.transport("无法从服务器地址拼出流式地址")))
            continuation.finish()
            self.continuation = nil
            return stream
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        let auth: [String: Any] = [
            "type": "auth",
            // Raw key, no "Bearer " prefix: the contract says so.
            "token": apiKey,
            "language": language,
            "max_speakers": maxSpeakers,
            "offline_correction": true,
            "session_id": UUID().uuidString
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: auth)
            let message = URLSessionWebSocketTask.Message.string(String(decoding: data, as: UTF8.self))
            task.send(message) { [weak self] error in
                if let error {
                    Task { await self?.emitFailure(.transport("auth 发送失败：\(error.localizedDescription)")) }
                }
            }
        } catch {
            emitFailure(.transport("auth 编码失败：\(error.localizedDescription)"))
            return stream
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        return stream
    }

    /// Sends one chunk of 16 kHz mono PCM16 audio as a binary frame.
    /// Callers forward `StreamingAudioCapture`'s stream verbatim: that
    /// capture is already 16 kHz mono Int16 (see its `sampleRate` and
    /// `captureFormat`), so no resampling or second capture is needed.
    func sendAudioChunk(_ data: Data) {
        guard let task else { return }
        task.send(.data(data)) { [weak self] error in
            if let error {
                Task { await self?.emitFailure(.transport("音频发送失败：\(error.localizedDescription)")) }
            }
        }
    }

    /// Sends the contract's end frame. The caller still disconnects
    /// afterwards (see `StreamingMeetingSession.stop`): the end frame
    /// asks the server to finish, it does not close the socket by itself.
    func sendEnd() {
        guard let task else { return }
        task.send(.string(#"{"type":"end"}"#)) { _ in }
    }

    /// Idempotent. Finishing the continuation ends the caller's event
    /// loop; the nil checks make a repeated call a no-op.
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if let continuation {
            self.continuation = nil
            continuation.finish()
        }
    }

    // MARK: - Private

    /// http(s) -> ws(s) + `/v1/stream`. A path already on the base URL
    /// is kept as a prefix; the config URL is normally bare-host.
    static func streamURL(from serverURL: URL) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        let basePath = components.path
        let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        components.path = trimmedBase + "/v1/stream"
        return components.url
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                handleMessage(message)
                // `session_end` and failures finish the continuation;
                // once it is gone there is nothing left to receive.
                if continuation == nil { return }
            } catch {
                if !Task.isCancelled {
                    emitFailure(.transport("接收失败：\(error.localizedDescription)"))
                }
                return
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: text = nil
        }
        guard let text, let frame = StreamingServerMessageParser.frame(text) else {
            logger.logError("流式：无法解析服务器帧")
            return
        }
        // An unknown `type` is not an error - it is simply a frame this client
        // does not consume - so the parse failure above stays the only log line.
        guard let event = StreamingServerMessageParser.event(from: frame) else { return }
        continuation?.yield(event)
        if case .sessionEnded = event {
            if let continuation {
                self.continuation = nil
                continuation.finish()
            }
        }
    }

    private func emitFailure(_ error: StreamingError) {
        logger.logError("流式：\(error.message)")
        continuation?.yield(.failed(error))
        if let continuation {
            self.continuation = nil
            continuation.finish()
        }
    }

}

/// The dictation session drives the socket through this seam, so its
/// end-of-audio and failure handling can be tested without a server. The
/// meeting screen keeps talking to the actor directly.
extension StreamingWebSocketClient: StreamingServerConnection {}
