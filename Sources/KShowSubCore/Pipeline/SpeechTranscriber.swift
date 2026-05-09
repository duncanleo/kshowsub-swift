import AVFoundation
import Foundation
import Speech
import SubtitleKit

public enum SpeechTranscriberError: LocalizedError {
    case transcriberUnavailable
    case localeNotSupported
    case noAudioTrack
    case exportFailed(String)
    case analysisFailed(String)
    case assetInstallationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .transcriberUnavailable:
            return "Speech transcriber is unavailable on this device."
        case .localeNotSupported:
            return "The specified locale is not supported for transcription."
        case .noAudioTrack:
            return "Video has no audio track."
        case .exportFailed(let msg):
            return "Failed to export audio: \(msg)"
        case .analysisFailed(let msg):
            return "Speech analysis failed: \(msg)"
        case .assetInstallationFailed(let msg):
            return "Failed to install speech assets: \(msg)"
        }
    }
}

public actor VideoSpeechTranscriber: VideoSpeechTranscribing {
    private let locale: Locale

    public init(locale: Locale = .init(identifier: "en-US")) {
        self.locale = locale
    }

    public func transcribe(videoURL: URL) async throws -> [SubtitleCue] {
        let audioURL = try await exportAudio(from: videoURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        return try await analyzeWithSpeechAnalyzer(audioURL: audioURL)
    }

    private func exportAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SpeechTranscriberError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SpeechTranscriberError.exportFailed("Could not create composition track")
        }

        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw SpeechTranscriberError.exportFailed("Could not create export session")
        }

        session.outputURL = outputURL
        session.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume(returning: ()) }
        }

        if let error = session.error {
            throw SpeechTranscriberError.exportFailed(error.localizedDescription)
        }
        if session.status != .completed {
            throw SpeechTranscriberError.exportFailed("Export status: \(session.status.rawValue)")
        }

        return outputURL
    }

    private func analyzeWithSpeechAnalyzer(audioURL: URL) async throws -> [SubtitleCue] {
        guard let supportedLocale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechTranscriberError.localeNotSupported
        }

        let transcriber = Speech.SpeechTranscriber(
            locale: supportedLocale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        guard Speech.SpeechTranscriber.isAvailable else {
            throw SpeechTranscriberError.transcriberUnavailable
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            do {
                try await request.downloadAndInstall()
            } catch {
                throw SpeechTranscriberError.assetInstallationFailed(error.localizedDescription)
            }
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeechTranscriberError.exportFailed("Could not open audio file: \(error.localizedDescription)")
        }

        let sampleRate = audioFile.fileFormat.sampleRate
        let totalSeconds = sampleRate > 0 ? Double(audioFile.length) / sampleRate : 0
        print("Speech: transcribing \(String(format: "%.1f", totalSeconds))s of audio...")
        defer { fputs("\r                    \r", stderr) }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        var analysisError: Error?

        let resultsTask = Task {
            var collected: [SubtitleCue] = []
            var nextId = 1
            do {
                for try await result in transcriber.results {
                    for cue in extractCues(from: result, startingId: nextId) {
                        collected.append(cue)
                        nextId += 1
                    }
                    let maxEnd = Self.maxEndSeconds(from: result)
                    if totalSeconds > 0.001 {
                        let pct = min(100, Int((maxEnd / totalSeconds) * 100))
                        fputs(
                            "\rSpeech \(pct)% (\(String(format: "%.1f", maxEnd))s / \(String(format: "%.1f", totalSeconds))s)...",
                            stderr)
                    } else {
                        fputs("\rSpeech \(collected.count) cues...", stderr)
                    }
                }
            } catch {
                throw error
            }
            return (collected, nextId)
        }

        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                try await analyzer.cancelAndFinishNow()
            }
        } catch {
            analysisError = error
        }

        let (collected, _) = try await resultsTask.value
        if let analysisError {
            throw SpeechTranscriberError.analysisFailed(analysisError.localizedDescription)
        }
        return collected
    }

    private static func maxEndSeconds(from result: Speech.SpeechTranscriber.Result) -> Double {
        var maxEnd: Double = 0
        for run in result.text.runs {
            guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                continue
            }
            let end = CMTimeGetSeconds(timeRange.start) + CMTimeGetSeconds(timeRange.duration)
            maxEnd = Swift.max(maxEnd, end)
        }
        return maxEnd
    }

    private func extractCues(from result: Speech.SpeechTranscriber.Result, startingId: Int) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var id = startingId
        let text = result.text

        for run in text.runs {
            guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else {
                continue
            }
            let runText = String(text[run.range].characters).trimmingCharacters(in: .whitespaces)
            guard !runText.isEmpty else { continue }

            let startSeconds = CMTimeGetSeconds(timeRange.start)
            let durationSeconds = CMTimeGetSeconds(timeRange.duration)
            let startMs = Int(startSeconds * 1000)
            let endMs = Int((startSeconds + durationSeconds) * 1000)

            cues.append(SubtitleCue(
                id: id,
                startTime: startMs,
                endTime: endMs,
                rawText: runText,
                plainText: runText,
                attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
            ))
            id += 1
        }

        if cues.isEmpty {
            let plainText = String(text.characters).trimmingCharacters(in: .whitespaces)
            if !plainText.isEmpty {
                cues.append(SubtitleCue(
                    id: id,
                    startTime: 0,
                    endTime: 1000,
                    rawText: plainText,
                    plainText: plainText,
                    attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
                ))
            }
        }

        return cues
    }
}
