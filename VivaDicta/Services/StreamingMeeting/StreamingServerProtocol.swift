// Copyright © 2026 Anton Novoselov. All rights reserved.

import Foundation

/// The self-hosted streaming ASR wire contract, carved out of
/// `StreamingWebSocketClient` so it can be exercised without a socket.
///
/// Everything here is Foundation-only on purpose: the meeting screen and the
/// dictation session both speak this contract, and the frame decoding is the
/// one place a field name is allowed to appear. Nothing in this file opens a
/// connection, reads a clock, or touches app state.

/// Server-side speaker confirmation state, carried verbatim from the
/// streaming contract's `speaker_status` field.
enum StreamingSpeakerStatus: String, Sendable {
    case provisional
    case confirmed
    case uncertain
}

/// One segment affected by a `speaker_update` frame, keyed by the
/// contract's `segment_id` (never by list position).
struct StreamingSpeakerUpdateSegment: Sendable {
    let segmentID: String
    let speakerLabel: String?
}

/// Failure of the streaming connection. A server `error` frame keeps its
/// `code` verbatim: the session layer matches
/// `streaming_unsupported_language` on it to fall back to the old path,
/// so this type must never rewrite or localise the code.
enum StreamingError: Error, Sendable {
    case transport(String)
    case server(code: String, message: String)

    /// The server error code, if this failure came from an `error` frame.
    var serverCode: String? {
        if case .server(let code, _) = self { return code }
        return nil
    }

    var message: String {
        switch self {
        case .transport(let text): return text
        case .server(_, let text): return text
        }
    }
}

/// One decoded event from the streaming server.
///
/// `StreamingWebSocketClient.Event` is a type alias for this, so the meeting
/// screen's call sites are unchanged; the types moved here only so dictation
/// can consume the same events without linking the socket itself.
enum StreamingServerEvent: Sendable {
    case ready
    case interimSegment(
        segmentID: String,
        text: String,
        speakerLabel: String?,
        start: Double,
        end: Double
    )
    case finalSegment(
        segmentID: String,
        text: String,
        speakerLabel: String?,
        status: StreamingSpeakerStatus,
        confidence: Double?,
        start: Double,
        end: Double,
        corrected: Bool
    )
    case speakerUpdated(
        remap: [String: String],
        segments: [StreamingSpeakerUpdateSegment]
    )
    case failed(StreamingError)
    case sessionEnded
}

/// Decodes one text frame of the streaming contract into an event.
///
/// A frame that does not parse returns nil (the caller logs it); a frame whose
/// `type` this client does not consume also returns nil from `event(from:)`
/// but is still a valid `Frame`, so an unknown type is silent rather than an
/// error in the log.
///
/// Pure JSON decoding, no state and no actor affinity: `nonisolated` so the
/// socket actor (`StreamingWebSocketClient`) and the dictation actor
/// (`SelfHostedRealtimeSession`) can both call it. Without it Swift 6 infers
/// MainActor isolation for this type and the two actors cannot use it.
nonisolated enum StreamingServerMessageParser {
    /// One frame of the streaming contract. All names are the contract's
    /// names, not Swift-style renames; `speaker_label` is optional
    /// because interim frames carry null until a speaker is assigned.
    struct Frame: Decodable {
        let type: String
        let segmentID: String?
        let text: String?
        let speakerLabel: String?
        let speakerStatus: String?
        let start: Double?
        let end: Double?
        let confidence: Double?
        let corrected: Bool?
        let remap: [String: String]?
        let segments: [FrameSegment]?
        let code: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case type
            case segmentID = "segment_id"
            case text
            case speakerLabel = "speaker_label"
            case speakerStatus = "speaker_status"
            case start
            case end
            case confidence
            case corrected
            case remap
            case segments
            case code
            case message
        }

        struct FrameSegment: Decodable {
            let segmentID: String
            let speakerLabel: String?

            enum CodingKeys: String, CodingKey {
                case segmentID = "segment_id"
                case speakerLabel = "speaker_label"
            }
        }
    }

    /// JSON decode only - no socket, no state.
    static func frame(_ text: String) -> Frame? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Frame.self, from: data)
    }

    /// One text frame -> one event, or nil when the frame is not JSON of the
    /// expected shape or carries a `type` this client does not consume.
    static func event(from text: String) -> StreamingServerEvent? {
        guard let frame = frame(text) else { return nil }
        return event(from: frame)
    }

    static func event(from frame: Frame) -> StreamingServerEvent? {
        switch frame.type {
        case "ready":
            return .ready
        case "interim":
            guard let segmentID = frame.segmentID, let segmentText = frame.text else { return nil }
            return .interimSegment(
                segmentID: segmentID,
                text: segmentText,
                speakerLabel: frame.speakerLabel,
                start: frame.start ?? 0,
                end: frame.end ?? 0
            )
        case "final":
            guard let segmentID = frame.segmentID, let segmentText = frame.text else { return nil }
            let status: StreamingSpeakerStatus
            switch frame.speakerStatus {
            case "uncertain": status = .uncertain
            case "provisional": status = .provisional
            default: status = .confirmed
            }
            return .finalSegment(
                segmentID: segmentID,
                text: segmentText,
                speakerLabel: frame.speakerLabel,
                status: status,
                confidence: frame.confidence,
                start: frame.start ?? 0,
                end: frame.end ?? 0,
                corrected: frame.corrected ?? false
            )
        case "speaker_update":
            let segments = (frame.segments ?? []).map {
                StreamingSpeakerUpdateSegment(segmentID: $0.segmentID, speakerLabel: $0.speakerLabel)
            }
            return .speakerUpdated(remap: frame.remap ?? [:], segments: segments)
        case "error":
            // Verbatim passthrough: the session matches
            // `streaming_unsupported_language` on `code` for fallback.
            return .failed(.server(
                code: frame.code ?? "",
                message: frame.message ?? "服务器错误"
            ))
        case "session_end":
            return .sessionEnded
        default:
            return nil
        }
    }
}
