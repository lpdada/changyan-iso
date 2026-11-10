// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation
import Keychain
import Testing
@testable import VivaDicta

/// Covers the self-hosted streaming path for dictation: the wire contract parsed
/// out of the meeting path, the merge rules that turn segments into one
/// transcript, what happens at end-of-audio and on a drop, and the model
/// registration that routes a selection here.
///
/// Nothing in here opens a socket or contacts the server: the frames below are
/// the shapes the contract defines, and `ManualStreamingServer` plays the server.
@MainActor
struct SelfHostedStreamingDictationTests {

    // MARK: - Fixtures (the meeting path's frame shapes)

    private static let readyFrame = #"{"type":"ready","session_id":"9f0d…"}"#

    private static let interimFrame = """
    {"type":"interim","segment_id":"seg-1","text":"我今天","speaker_label":null,"start":0.0,"end":0.8}
    """

    private static let finalFrame = """
    {"type":"final","segment_id":"seg-1","text":"我今天开会。","speaker_label":"A",\
    "speaker_status":"confirmed","confidence":0.91,"start":0.0,"end":1.2,"corrected":false}
    """

    private static let correctedFrame = """
    {"type":"final","segment_id":"seg-1","text":"我今天开会，讨论流式转写。","speaker_label":"A",\
    "speaker_status":"confirmed","confidence":0.97,"start":0.0,"end":1.2,"corrected":true}
    """

    private static let speakerUpdateFrame = """
    {"type":"speaker_update","remap":{"A":"B"},"segments":[{"segment_id":"seg-1","speaker_label":"B"}]}
    """

    private static let errorFrame = """
    {"type":"error","code":"streaming_unsupported_language","message":"语言不支持：fr"}
    """

    private static let sessionEndFrame = #"{"type":"session_end"}"#

    // MARK: - Parsing

    @Test func readyFrameParses() {
        #expect(StreamingServerMessageParser.event(from: Self.readyFrame)?.isReady == true)
    }

    @Test func interimFrameKeepsItsSegmentIDAndText() throws {
        let event = try #require(StreamingServerMessageParser.event(from: Self.interimFrame))

        guard case .interimSegment(let segmentID, let text, let speakerLabel, let start, let end) = event else {
            Issue.record("expected an interim segment, got \(event)")
            return
        }
        #expect(segmentID == "seg-1")
        #expect(text == "我今天")
        #expect(speakerLabel == nil)
        #expect(start == 0)
        #expect(end == 0.8)
    }

    @Test func finalFrameCarriesStatusConfidenceAndCorrection() throws {
        let event = try #require(StreamingServerMessageParser.event(from: Self.finalFrame))

        guard case .finalSegment(let segmentID, let text, let speakerLabel, let status, let confidence, _, _, let corrected) = event else {
            Issue.record("expected a final segment, got \(event)")
            return
        }
        #expect(segmentID == "seg-1")
        #expect(text == "我今天开会。")
        #expect(speakerLabel == "A")
        #expect(status == .confirmed)
        #expect(confidence == 0.91)
        #expect(corrected == false)
    }

    @Test func correctedFinalFrameIsFlaggedAsCorrected() throws {
        let event = try #require(StreamingServerMessageParser.event(from: Self.correctedFrame))

        guard case .finalSegment(_, let text, _, _, _, _, _, let corrected) = event else {
            Issue.record("expected a final segment, got \(event)")
            return
        }
        #expect(text == "我今天开会，讨论流式转写。")
        #expect(corrected)
    }

    @Test func speakerUpdateFrameKeepsSegmentIdentity() throws {
        let event = try #require(StreamingServerMessageParser.event(from: Self.speakerUpdateFrame))

        guard case .speakerUpdated(let remap, let segments) = event else {
            Issue.record("expected a speaker update, got \(event)")
            return
        }
        #expect(remap == ["A": "B"])
        #expect(segments.map(\.segmentID) == ["seg-1"])
        #expect(segments.first?.speakerLabel == "B")
    }

    /// The error code is the whole fallback contract: matching it on a
    /// localised string would break the moment somebody rewords the message.
    @Test func errorFrameKeepsItsServerCodeVerbatim() throws {
        let event = try #require(StreamingServerMessageParser.event(from: Self.errorFrame))

        guard case .failed(let error) = event else {
            Issue.record("expected a failure, got \(event)")
            return
        }
        #expect(error.serverCode == "streaming_unsupported_language")
        #expect(error.message == "语言不支持：fr")
    }

    @Test func sessionEndFrameParses() {
        #expect(StreamingServerMessageParser.event(from: Self.sessionEndFrame)?.isSessionEnd == true)
    }

    @Test(arguments: [
        "",
        "not json at all",
        #"{"session_id":"x"}"#,          // no `type`
        "["                              // valid JSON, wrong shape
    ])
    func undecodableFramesReturnNoEvent(text: String) {
        #expect(StreamingServerMessageParser.event(from: text) == nil)
    }

    /// A frame this client does not consume must not look like a parse error:
    /// an unknown `type` decodes fine and simply yields no event.
    @Test func unknownFrameTypeIsSilentlyIgnored() {
        let text = #"{"type":"heartbeat","segment_id":"seg-1"}"#

        #expect(StreamingServerMessageParser.frame(text) != nil)
        #expect(StreamingServerMessageParser.event(from: text) == nil)
    }

    // MARK: - Merge rules

    @Test func interimIsReplacedInPlaceNotAppended() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyInterim(segmentID: "seg-1", text: "我今")
        sut.applyInterim(segmentID: "seg-1", text: "我今天")
        sut.applyInterim(segmentID: "seg-1", text: "我今天开")

        #expect(sut.text == "我今天开")
        #expect(sut.segments.count == 1)
        #expect(sut.finalText.isEmpty)
    }

    @Test func finalReplacesTheInterimForTheSameSegment() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyInterim(segmentID: "seg-1", text: "我今天开")
        sut.applyFinal(segmentID: "seg-1", text: "我今天开会。", corrected: false)

        #expect(sut.text == "我今天开会。")
        #expect(sut.finalText == "我今天开会。")
        #expect(sut.segments.count == 1)
    }

    /// The end-of-audio correction pass is authoritative: when it lands, it is
    /// the text that gets saved.
    @Test func correctedFinalIsAdopted() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyFinal(segmentID: "seg-1", text: "我今天开会。", corrected: false)
        sut.applyFinal(segmentID: "seg-1", text: "我今天开会，讨论流式转写。", corrected: true)

        #expect(sut.text == "我今天开会，讨论流式转写。")
    }

    @Test func plainFinalCannotUndoACorrectedOne() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyFinal(segmentID: "seg-1", text: "我今天开会，讨论流式转写。", corrected: true)
        sut.applyFinal(segmentID: "seg-1", text: "我今天开会。", corrected: false)

        #expect(sut.text == "我今天开会，讨论流式转写。")
    }

    @Test func lateInterimCannotWaterDownAFinal() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyFinal(segmentID: "seg-1", text: "我今天开会。", corrected: false)
        sut.applyInterim(segmentID: "seg-1", text: "我今天")

        #expect(sut.text == "我今天开会。")
    }

    @Test func segmentsKeepFirstAppearanceOrder() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyFinal(segmentID: "seg-2", text: "第二句。", corrected: false)
        sut.applyFinal(segmentID: "seg-1", text: "第一句。", corrected: false)
        sut.applyFinal(segmentID: "seg-2", text: "第二句，修正。", corrected: true)

        #expect(sut.segments.map(\.segmentID) == ["seg-2", "seg-1"])
        #expect(sut.text == "第二句，修正。第一句。")
    }

    @Test func chineseSegmentsJoinWithoutSpaces() {
        let sut = SelfHostedStreamingTranscript.join(["我先说两句。", "然后是重点。"])

        #expect(sut == "我先说两句。然后是重点。")
    }

    @Test func latinSegmentsJoinWithASingleSpace() {
        let sut = SelfHostedStreamingTranscript.join(["Send the report", "by Friday"])

        #expect(sut == "Send the report by Friday")
    }

    @Test func mixedScriptBoundariesDoNotGetADoubleSeparator() {
        #expect(SelfHostedStreamingTranscript.join(["这是 API", "的用法"]) == "这是 API的用法")
        #expect(SelfHostedStreamingTranscript.join(["OK 我们开始", "now"]) == "OK 我们开始now")
    }

    @Test func existingWhitespaceIsNotDoubled() {
        #expect(SelfHostedStreamingTranscript.join(["one ", "two"]) == "one two")
        #expect(SelfHostedStreamingTranscript.join(["one", " two"]) == "one two")
    }

    @Test func emptySegmentsAreDropped() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyInterim(segmentID: "seg-1", text: "   ")
        sut.applyFinal(segmentID: "seg-2", text: "有内容。", corrected: false)
        sut.applyFinal(segmentID: "seg-3", text: "", corrected: false)

        #expect(sut.segments.count == 1)
        #expect(sut.text == "有内容。")
    }

    @Test func finalsOnlyTextExcludesAProvisionalTail() {
        var sut = SelfHostedStreamingTranscript()

        sut.applyFinal(segmentID: "seg-1", text: "定稿。", corrected: false)
        sut.applyInterim(segmentID: "seg-2", text: "还没定稿")

        #expect(sut.finalText == "定稿。")
        #expect(sut.text == "定稿。还没定稿")
    }

    // MARK: - Session behaviour

    @Test func finishReturnsTheJoinedTranscriptAfterSessionEnd() async throws {
        let server = ManualStreamingServer()
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: server,
            finalizeTimeout: .seconds(2)
        )

        await sut.start(apiKey: "key", languageHints: ["zh"], vocabularyTerms: [])
        await server.emit(.ready)
        await server.emit(.interimSegment(
            segmentID: "seg-1", text: "我今天", speakerLabel: nil, start: 0, end: 0.5
        ))
        await server.emit(.finalSegment(
            segmentID: "seg-1", text: "我今天开会。", speakerLabel: "A",
            status: .confirmed, confidence: 0.9, start: 0, end: 1, corrected: false
        ))
        await server.emit(.finalSegment(
            segmentID: "seg-2", text: "讨论流式转写。", speakerLabel: "A",
            status: .confirmed, confidence: 0.9, start: 1, end: 2, corrected: false
        ))
        await server.emit(.sessionEnded)

        await sut.send(Data([0x00, 0x01]))
        let text = try await sut.finish()
        let didSendEnd = await server.didSendEnd
        let receivedChunks = await server.receivedChunks
        let didDisconnect = await server.didDisconnect

        #expect(text == "我今天开会。讨论流式转写。")
        #expect(didSendEnd)
        #expect(receivedChunks == 1)
        #expect(didDisconnect)
    }

    @Test func endOfAudioUsesTheCorrectedFinalWhenItArrivesLast() async throws {
        let server = ManualStreamingServer()
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: server,
            finalizeTimeout: .seconds(2)
        )

        await sut.start(apiKey: "key", languageHints: [], vocabularyTerms: [])
        await server.emit(.ready)
        await server.emit(.finalSegment(
            segmentID: "seg-1", text: "我今天开会。", speakerLabel: "A",
            status: .confirmed, confidence: 0.9, start: 0, end: 1, corrected: false
        ))
        await server.emit(.finalSegment(
            segmentID: "seg-1", text: "我今天开会，讨论流式转写。", speakerLabel: "A",
            status: .confirmed, confidence: 0.97, start: 0, end: 1, corrected: true
        ))
        await server.emit(.sessionEnded)

        let text = try await sut.finish()
        #expect(text == "我今天开会，讨论流式转写。")
    }

    /// A stream that ends without `session_end` is a disconnect, not a short
    /// recording: `finish()` throws so the caller uploads the WAV instead of
    /// saving truncated text as a success.
    @Test func streamEndingWithoutSessionEndThrows() async {
        let server = ManualStreamingServer()
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: server,
            finalizeTimeout: .seconds(1)
        )

        await sut.start(apiKey: "key", languageHints: [], vocabularyTerms: [])
        await server.emit(.ready)
        await server.emit(.finalSegment(
            segmentID: "seg-1", text: "说了一半", speakerLabel: nil,
            status: .provisional, confidence: nil, start: 0, end: 1, corrected: false
        ))
        await server.finishStream()
        // Let the receive loop observe the end before finish() reads the flag.
        try? await Task.sleep(for: .milliseconds(100))

        await expectFailure(from: sut)
    }

    @Test func serverErrorFrameFailsTheSession() async {
        let server = ManualStreamingServer()
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: server,
            finalizeTimeout: .seconds(1)
        )

        await sut.start(apiKey: "key", languageHints: ["fr"], vocabularyTerms: [])
        await server.emit(.failed(.server(code: "streaming_unsupported_language", message: "语言不支持：fr")))

        let message = await failureMessage(from: sut)
        #expect(message?.contains("语言不支持：fr") == true)
    }

    @Test func transportFailureFailsTheSession() async {
        let server = ManualStreamingServer()
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: server,
            finalizeTimeout: .seconds(1)
        )

        await sut.start(apiKey: "key", languageHints: [], vocabularyTerms: [])
        await server.emit(.failed(.transport("接收失败：网络中断")))

        let message = await failureMessage(from: sut)
        #expect(message?.contains("网络中断") == true)
    }

    @Test func confirmWithoutAnyTextThrowsProducedNoText() async {
        let server = ManualStreamingServer()
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: server,
            finalizeTimeout: .seconds(1)
        )

        await sut.start(apiKey: "key", languageHints: [], vocabularyTerms: [])
        await server.emit(.ready)
        await server.emit(.sessionEnded)

        do {
            _ = try await sut.finish()
            Issue.record("expected producedNoText")
        } catch let error as RealtimeDictationSessionError {
            guard case .producedNoText = error else {
                Issue.record("expected producedNoText, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func finishWithoutStartThrows() async {
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: ManualStreamingServer()
        )

        await expectFailure(from: sut)
    }

    @Test func cancelClosesTheSocketWithoutThrowing() async {
        let server = ManualStreamingServer()
        let sut = SelfHostedRealtimeSession(
            serverURL: URL(string: "https://asr.example.test")!,
            connection: server,
            finalizeTimeout: .seconds(1)
        )

        await sut.start(apiKey: "key", languageHints: [], vocabularyTerms: [])
        await sut.cancel()
        let didDisconnect = await server.didDisconnect

        #expect(didDisconnect)
    }

    @Test(arguments: [(["zh"], "zh"), ([], "auto"), ([""], "auto"), (["en", "zh"], "en")])
    func languageHintBecomesTheContractsSingleLanguage(hints: [String], expected: String) {
        #expect(SelfHostedRealtimeSession.language(hints: hints) == expected)
    }

    // MARK: - Registration

    @Test func selfHostedStreamingModelIsRegistered() {
        #expect(TranscriptionModelProvider.isStreamingModel(TranscriptionModelProvider.selfHostedRealtimeModel))
    }

    @Test func selfHostedBatchModelIsNotStreaming() {
        #expect(TranscriptionModelProvider.isStreamingModel(TranscriptionModelProvider.selfHostedBatchModel) == false)
    }

    /// The socket slug is not a model the upload endpoint serves, so both the
    /// keyboard path and the dropped-socket fallback must send the server's own
    /// default batch model.
    @Test func selfHostedStreamingModelMapsToTheBatchDefaultOnUpload() {
        let mapped = TranscriptionModelProvider.asyncEquivalent(of: TranscriptionModelProvider.selfHostedRealtimeModel)

        #expect(mapped == TranscriptionModelProvider.selfHostedBatchModel)
        #expect(mapped != TranscriptionModelProvider.selfHostedRealtimeModel)
    }

    /// The mapped name has to be a real entry under the same provider, otherwise
    /// the fallback lands on a 400 from the server instead of transcribing.
    @Test func uploadFallbackNamesAnExistingSelfHostedModel() throws {
        let mapped = TranscriptionModelProvider.asyncEquivalent(of: TranscriptionModelProvider.selfHostedRealtimeModel)
        let model = try #require(
            TranscriptionModelProvider.allCloudModels.first { $0.name == mapped }
        )

        #expect(model.provider == .selfHosted)
    }

    /// The batch default is what the provider switch picks for a new mode, so it
    /// has to stay the first entry in the self-hosted catalog - pinning it
    /// catches an insert that would silently change every new mode's default.
    @Test func selfHostedCatalogDefaultIsUnchanged() {
        let names = TranscriptionModelProvider.selfHosted.cloudTranscriptionModelsNames

        #expect(names.first == TranscriptionModelProvider.selfHostedBatchModel)
    }

    @Test func catalogOffersTheStreamingModelUnselected() {
        let names = TranscriptionModelProvider.selfHosted.cloudTranscriptionModelsNames

        #expect(names.contains(TranscriptionModelProvider.selfHostedRealtimeModel))
        // Appended, never first: no existing default moves.
        #expect(names.first != TranscriptionModelProvider.selfHostedRealtimeModel)
    }

    // MARK: - Key routing and fallback

    @Test func missingSelfHostedKeyFallsBackInsteadOfRecordingAnError() {
        let mode = Self.mode(model: TranscriptionModelProvider.selfHostedRealtimeModel)

        let canHandle = RealtimeDictationCoordinator.canHandle(
            mode: mode,
            modelName: TranscriptionModelProvider.selfHostedRealtimeModel,
            keychain: EmptyKeychain()
        )

        #expect(canHandle == false)
    }

    @Test func presentSelfHostedKeyEnablesTheSocket() {
        let mode = Self.mode(model: TranscriptionModelProvider.selfHostedRealtimeModel)

        let canHandle = RealtimeDictationCoordinator.canHandle(
            mode: mode,
            modelName: TranscriptionModelProvider.selfHostedRealtimeModel,
            keychain: FixedKeychain(value: "self-hosted-key")
        )

        #expect(canHandle)
    }

    @Test func translationModesStayOnTheUploadPath() {
        let mode = Self.mode(
            model: TranscriptionModelProvider.selfHostedRealtimeModel,
            translationTargetLanguage: "ru"
        )

        let canHandle = RealtimeDictationCoordinator.canHandle(
            mode: mode,
            modelName: TranscriptionModelProvider.selfHostedRealtimeModel,
            keychain: FixedKeychain(value: "self-hosted-key")
        )

        #expect(canHandle == false)
    }

    @Test func speakerLabelModesStayOnTheUploadPath() {
        let mode = Self.mode(
            model: TranscriptionModelProvider.selfHostedRealtimeModel,
            speakerLabelsEnabled: true
        )

        let canHandle = RealtimeDictationCoordinator.canHandle(
            mode: mode,
            modelName: TranscriptionModelProvider.selfHostedRealtimeModel,
            keychain: FixedKeychain(value: "self-hosted-key")
        )

        #expect(canHandle == false)
    }

    // MARK: - Helpers

    private static func mode(
        model: String,
        translationTargetLanguage: String? = nil,
        speakerLabelsEnabled: Bool = false
    ) -> VivaMode {
        VivaMode(
            id: UUID(),
            name: "Dictation",
            transcriptionProvider: .selfHosted,
            transcriptionModel: model,
            transcriptionLanguage: "zh",
            translationTargetLanguage: translationTargetLanguage,
            aiModel: "",
            aiEnhanceEnabled: false,
            speakerLabelsEnabled: speakerLabelsEnabled
        )
    }

    private func expectFailure(from session: SelfHostedRealtimeSession) async {
        do {
            _ = try await session.finish()
            Issue.record("expected finish() to throw so the caller falls back to the file")
        } catch is RealtimeDictationSessionError {
            // Expected: every incomplete outcome is a failure, never a short text.
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private func failureMessage(from session: SelfHostedRealtimeSession) async -> String? {
        do {
            _ = try await session.finish()
            Issue.record("expected finish() to throw so the caller falls back to the file")
            return nil
        } catch let error as RealtimeDictationSessionError {
            return error.errorDescription
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }
}

// MARK: - Doubles

/// Plays the server: the test emits frames, `finish()` supplies the end frame.
private actor ManualStreamingServer: StreamingServerConnection {
    private var continuation: AsyncStream<StreamingServerEvent>.Continuation?
    private(set) var receivedChunks = 0
    private(set) var didSendEnd = false
    private(set) var didDisconnect = false

    func connect(
        serverURL: URL,
        apiKey: String,
        language: String,
        maxSpeakers: Int
    ) -> AsyncStream<StreamingServerEvent> {
        let (stream, continuation) = AsyncStream<StreamingServerEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func sendAudioChunk(_ data: Data) {
        receivedChunks += 1
    }

    func sendEnd() {
        didSendEnd = true
    }

    func disconnect() {
        didDisconnect = true
        continuation?.finish()
        continuation = nil
    }

    /// Server -> client frame.
    func emit(_ event: StreamingServerEvent) {
        continuation?.yield(event)
    }

    /// Socket closed by the peer without a `session_end`.
    func finishStream() {
        continuation?.finish()
        continuation = nil
    }
}

private struct EmptyKeychain: KeychainService {
    func save(_ value: String, forKey key: String, syncable: Bool) -> Bool { false }
    func save(data: Data, forKey key: String, syncable: Bool) -> Bool { false }
    func getString(forKey key: String, syncable: Bool) -> String? { nil }
    func getData(forKey key: String, syncable: Bool) -> Data? { nil }
    func delete(forKey key: String, syncable: Bool) -> Bool { false }
}

private struct FixedKeychain: KeychainService {
    let value: String

    func save(_ value: String, forKey key: String, syncable: Bool) -> Bool { true }
    func save(data: Data, forKey key: String, syncable: Bool) -> Bool { true }
    func getString(forKey key: String, syncable: Bool) -> String? { value }
    func getData(forKey key: String, syncable: Bool) -> Data? { Data(value.utf8) }
    func delete(forKey key: String, syncable: Bool) -> Bool { true }
}

private extension StreamingServerEvent {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isSessionEnd: Bool {
        if case .sessionEnded = self { return true }
        return false
    }
}
