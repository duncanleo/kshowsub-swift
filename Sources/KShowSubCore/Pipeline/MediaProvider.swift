import Foundation
import SubtitleKit

public typealias OCRFrameRecordPersistence = @Sendable ([OCRFrameRecord]) async throws -> Void

/// Boundary for extracting dialogue cues from a video.
///
/// Implementations may use Apple's Speech framework, a local model, a remote service, or a
/// platform-specific adapter. Callers should depend on this protocol instead of concrete
/// framework-backed transcribers.
public protocol VideoSpeechTranscribing: Sendable {
    func transcribe(videoURL: URL) async throws -> [SubtitleCue]
}

/// Boundary for extracting on-screen text cues from a video.
///
/// Implementations are responsible for honoring the provided locale, sampling rate, profile,
/// and resumable frame records. A non-Apple backend can reuse `OCRTextObservation` records as
/// the persisted interchange format when it has bounding box data, or persist recognized text
/// only when it does not.
public protocol VideoOCRProcessing: Sendable {
    func extractText(
        videoURL: URL,
        locale: Locale,
        fps: Int,
        profile: OCRProfile,
        existingFrameRecords: [OCRFrameRecord],
        persistRecords: OCRFrameRecordPersistence?
    ) async throws -> [SubtitleCue]
}
