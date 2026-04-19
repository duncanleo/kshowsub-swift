import AVFoundation
import CoreGraphics
import Foundation
import os
import SubtitleKit
import Vision

private let logger = Logger(subsystem: "me.duncanleo.kshowsub", category: "OCR")

public enum OCRProcessorError: LocalizedError {
    case noVideoTrack
    case frameGenerationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "Video has no video track."
        case .frameGenerationFailed(let msg):
            return "Frame generation failed: \(msg)"
        }
    }
}

public actor OCRProcessor {
    public init() {}
    private struct PendingOCRFrame: @unchecked Sendable {
        let index: Int
        let image: CGImage
        let fingerprint: [UInt8]?
    }

    /// - Parameter fps: How many times per second to sample the video for on-screen text (must be ≥ 1).
    /// - Parameter profile: Tuning parameters controlling filtering, frame skipping, similarity
    ///   thresholds, and region exclusion.
    public func extractText(
        videoURL: URL,
        locale: Locale,
        fps: Int = 5,
        profile: OCRProfile = .default,
        existingFrameRecords: [OCRFrameRecord] = [],
        persistRecords: (@Sendable ([OCRFrameRecord]) async throws -> Void)? = nil
    ) async throws -> [SubtitleCue] {
        precondition(fps >= 1)
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw OCRProcessorError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let imageHeight = Double(naturalSize.height)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Fallback generator with relaxed tolerances for codecs that don't support exact seeking.
        let relaxedGenerator = AVAssetImageGenerator(asset: asset)
        relaxedGenerator.appliesPreferredTrackTransform = true

        let timescale: CMTimeScale = 600
        let fpsDouble = Double(fps)
        let frameCount = max(1, Int(ceil(totalSeconds * fpsDouble)))

        let cachedRecords = existingFrameRecords.prefix { $0.index < frameCount }
        let resumeIndex = cachedRecords.count
        var frameResults: [(Int, String)] = cachedRecords.compactMap { record in
            let text: String
            if let obs = record.observations {
                text = Self.filterAndJoin(
                    obs, imageHeight: imageHeight, profile: profile)
            } else {
                text = record.recognizedText
            }
            return text.isEmpty ? nil : (record.index, text)
        }

        if resumeIndex >= frameCount {
            logger.info("OCR: refiltering \(frameCount) cached frames...")
            return mergeConsecutiveDuplicates(
                frameResults: collapseTextNearDuplicates(frameResults, profile: profile),
                totalSeconds: totalSeconds, fps: fps)
        }

        logger.info("OCR: processing \(frameCount) frames (\(fps) fps)...")
        if resumeIndex > 0 {
            logger.info("OCR: resuming from frame \(resumeIndex + 1) of \(frameCount)...")
        }

        var previousFingerprint: [UInt8]? = cachedRecords.last?.fingerprint
        var lastObservations: [OCRTextObservation] = cachedRecords.last?.observations ?? []
        var pendingOCRFrames: [PendingOCRFrame] = []

        for k in resumeIndex..<frameCount {
            let seconds = Double(k) / fpsDouble
            let time = CMTime(seconds: seconds, preferredTimescale: timescale)

            let cgImage: CGImage = try await withCheckedThrowingContinuation { cont in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                    _, image, _, result, error in
                    switch result {
                    case .succeeded:
                        if let image {
                            cont.resume(returning: image)
                        } else {
                            cont.resume(
                                throwing: OCRProcessorError.frameGenerationFailed(
                                    "No image at \(seconds)s"))
                        }
                    case .failed:
                        // Retry with relaxed tolerances — some codecs don't support exact seeking.
                        relaxedGenerator.generateCGImagesAsynchronously(
                            forTimes: [NSValue(time: time)]
                        ) { _, fallbackImage, _, fallbackResult, fallbackError in
                            if fallbackResult == .succeeded, let fallbackImage {
                                cont.resume(returning: fallbackImage)
                            } else {
                                let msg =
                                    fallbackError?.localizedDescription
                                    ?? error?.localizedDescription
                                    ?? "No image at \(seconds)s"
                                cont.resume(
                                    throwing: OCRProcessorError.frameGenerationFailed(msg))
                            }
                        }
                    case .cancelled:
                        cont.resume(
                            throwing: OCRProcessorError.frameGenerationFailed(
                                "Cancelled at \(seconds)s"))
                    @unknown default:
                        cont.resume(
                            throwing: OCRProcessorError.frameGenerationFailed(
                                "Unknown result at \(seconds)s"))
                    }
                }
            }

            let currFingerprint = downsampledGrayscaleFingerprint(from: cgImage, profile: profile)
            let skipOCR: Bool =
                if profile.skipSimilarFrames, k > 0, let prev = previousFingerprint,
                    let curr = currFingerprint
                {
                    averageNormalizedPixelDifference(prev, curr) < profile.frameSimilaritySkipThreshold
                } else {
                    false
                }
            previousFingerprint = currFingerprint

            if skipOCR {
                let flushed = try await recognizePendingFrames(pendingOCRFrames, locale: locale)
                let flushedRecords = flushed.map { item in
                    OCRFrameRecord(
                        index: item.index,
                        sampleTimeSeconds: Double(item.index) / fpsDouble,
                        recognizedText: "",
                        observations: item.observations,
                        reusedPreviousText: false,
                        fingerprint: item.fingerprint
                    )
                }
                if let lastRecord = flushed.last {
                    lastObservations = lastRecord.observations
                }
                frameResults.append(
                    contentsOf: flushedRecords.compactMap { record in
                        guard let obs = record.observations else { return nil }
                        let text = Self.filterAndJoin(
                            obs, imageHeight: imageHeight, profile: profile)
                        return text.isEmpty ? nil : (record.index, text)
                    })
                if let persistRecords {
                    try await persistRecords(flushedRecords)
                }
                pendingOCRFrames.removeAll(keepingCapacity: true)

                let reusedText = Self.filterAndJoin(
                    lastObservations, imageHeight: imageHeight, profile: profile
                )
                if !reusedText.isEmpty {
                    frameResults.append((k, reusedText))
                }
                if let persistRecords {
                    try await persistRecords([
                        OCRFrameRecord(
                            index: k,
                            sampleTimeSeconds: seconds,
                            recognizedText: "",
                            observations: lastObservations,
                            reusedPreviousText: true,
                            fingerprint: currFingerprint
                        )
                    ])
                }
            } else {
                pendingOCRFrames.append(
                    PendingOCRFrame(index: k, image: cgImage, fingerprint: currFingerprint))
                if pendingOCRFrames.count >= profile.maxConcurrentOCRFrames {
                    let flushed = try await recognizePendingFrames(pendingOCRFrames, locale: locale)
                    let flushedRecords = flushed.map { item in
                        OCRFrameRecord(
                            index: item.index,
                            sampleTimeSeconds: Double(item.index) / fpsDouble,
                            recognizedText: "",
                            observations: item.observations,
                            reusedPreviousText: false,
                            fingerprint: item.fingerprint
                        )
                    }
                    if let lastRecord = flushed.last {
                        lastObservations = lastRecord.observations
                    }
                    frameResults.append(
                        contentsOf: flushedRecords.compactMap { record in
                            guard let obs = record.observations else { return nil }
                            let text = Self.filterAndJoin(
                                obs, imageHeight: imageHeight, profile: profile)
                            return text.isEmpty ? nil : (record.index, text)
                        })
                    if let persistRecords {
                        try await persistRecords(flushedRecords)
                    }
                    pendingOCRFrames.removeAll(keepingCapacity: true)
                }
            }
            fputs("\rOCR \(k + 1)/\(frameCount) frames...", stderr)
        }
        fputs("\r                    \r", stderr)

        let flushed = try await recognizePendingFrames(pendingOCRFrames, locale: locale)
        let flushedRecords = flushed.map { item in
            OCRFrameRecord(
                index: item.index,
                sampleTimeSeconds: Double(item.index) / fpsDouble,
                recognizedText: "",
                observations: item.observations,
                reusedPreviousText: false,
                fingerprint: item.fingerprint
            )
        }
        frameResults.append(
            contentsOf: flushedRecords.compactMap { record in
                guard let obs = record.observations else { return nil }
                let text = Self.filterAndJoin(
                    obs, imageHeight: imageHeight, profile: profile)
                return text.isEmpty ? nil : (record.index, text)
            })
        if let persistRecords {
            try await persistRecords(flushedRecords)
        }

        return mergeConsecutiveDuplicates(
            frameResults: collapseTextNearDuplicates(frameResults, profile: profile),
            totalSeconds: totalSeconds, fps: fps)
    }

    /// Small grayscale thumbnail for comparing consecutive frames. Nil if allocation or context fails.
    private func downsampledGrayscaleFingerprint(from cgImage: CGImage, profile: OCRProfile) -> [UInt8]? {
        let size = profile.frameSimilarityFingerprintSize
        let byteCount = size * size
        var data = [UInt8](repeating: 0, count: byteCount)
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)
        else { return nil }
        let ok = data.withUnsafeMutableBytes { ptr -> Bool in
            guard
                let base = ptr.baseAddress,
                let ctx = CGContext(
                    data: base,
                    width: size,
                    height: size,
                    bitsPerComponent: 8,
                    bytesPerRow: size,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return ok ? data : nil
    }

    /// Mean absolute difference per channel, normalized to 0…1 (for 8-bit grayscale).
    private func averageNormalizedPixelDifference(_ a: [UInt8], _ b: [UInt8]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum: Int = 0
        for i in a.indices {
            sum += Int(abs(Int32(a[i]) - Int32(b[i])))
        }
        return Float(sum) / Float(a.count * 255)
    }

    private func recognizePendingFrames(
        _ frames: [PendingOCRFrame],
        locale: Locale
    ) async throws -> [(index: Int, observations: [OCRTextObservation], fingerprint: [UInt8]?)] {
        guard !frames.isEmpty else { return [] }

        var recognizedByIndex: [Int: [OCRTextObservation]] = [:]
        try await withThrowingTaskGroup(of: (Int, [OCRTextObservation]).self) { group in
            for frame in frames {
                group.addTask {
                    let observations = try Self.recognizeText(in: frame.image, locale: locale)
                    return (frame.index, observations)
                }
            }

            for try await (index, observations) in group {
                recognizedByIndex[index] = observations
            }
        }

        return frames.map { frame in
            (frame.index, recognizedByIndex[frame.index] ?? [], frame.fingerprint)
        }
    }

    private static func recognizeText(
        in cgImage: CGImage,
        locale: Locale
    ) throws -> [OCRTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let localeId = locale.identifier
        request.recognitionLanguages = localeId.hasPrefix("en") ? [localeId] : [localeId, "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        return (request.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                !s.isEmpty
            else { return nil }
            return OCRTextObservation(
                text: s,
                boundingBoxX: Double(obs.boundingBox.origin.x),
                boundingBoxY: Double(obs.boundingBox.origin.y),
                boundingBoxWidth: Double(obs.boundingBox.width),
                boundingBoxHeight: Double(obs.boundingBox.height),
                topLeftX: Double(obs.topLeft.x),
                topLeftY: Double(obs.topLeft.y),
                topRightX: Double(obs.topRight.x),
                topRightY: Double(obs.topRight.y),
                bottomLeftX: Double(obs.bottomLeft.x),
                bottomLeftY: Double(obs.bottomLeft.y),
                bottomRightX: Double(obs.bottomRight.x),
                bottomRightY: Double(obs.bottomRight.y)
            )
        }
    }

    /// Returns the skew of an observation in degrees, measured as the angle of its text baseline
    /// from horizontal. Uses the average of the top and bottom edges when all four corners are
    /// available; falls back to the top edge alone, then nil if no corners exist.
    ///
    /// Vision coordinates have y increasing **upward**, so a perfectly level line has angle ≈ 0°.
    private static func skewDegrees(for obs: OCRTextObservation) -> Double? {
        func edgeAngle(x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
            atan2(y2 - y1, x2 - x1) * (180 / .pi)
        }

        let topAngle: Double?
        if let tlX = obs.topLeftX, let tlY = obs.topLeftY,
            let trX = obs.topRightX, let trY = obs.topRightY
        {
            topAngle = edgeAngle(x1: tlX, y1: tlY, x2: trX, y2: trY)
        } else {
            topAngle = nil
        }

        let bottomAngle: Double?
        if let blX = obs.bottomLeftX, let blY = obs.bottomLeftY,
            let brX = obs.bottomRightX, let brY = obs.bottomRightY
        {
            bottomAngle = edgeAngle(x1: blX, y1: blY, x2: brX, y2: brY)
        } else {
            bottomAngle = nil
        }

        switch (topAngle, bottomAngle) {
        case (let t?, let b?): return (t + b) / 2
        case (let t?, nil): return t
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }

    private static func filterAndJoin(
        _ observations: [OCRTextObservation],
        imageHeight: Double,
        profile: OCRProfile
    ) -> String {
        let filtered: [OCRTextObservation]
        if profile.filterLogoRegions {
            let minTextHeightPx = Double(profile.minimumRecognizedTextHeight) * imageHeight
            filtered = observations.filter { obs in
                guard obs.boundingBoxHeight * imageHeight >= minTextHeightPx else {
                    logger.debug(
                        "OCR: minimum height excluded \(obs.text, privacy: .public) percentage: \(obs.boundingBoxHeight / imageHeight)"
                    )
                    return false
                }
                let box = CGRect(
                    x: obs.boundingBoxX, y: obs.boundingBoxY,
                    width: obs.boundingBoxWidth, height: obs.boundingBoxHeight)
                if profile.shouldExclude(boundingBox: box) {
                    logger.debug("OCR: excluding \(obs.text, privacy: .public)")
                }
                // Ignore very narrow text (with a little margin)
                if (obs.boundingBoxWidth * 1.05) < obs.boundingBoxHeight {
                    logger.debug(
                        "OCR: ignoring very narrow text \(obs.text, privacy: .public) width: \(obs.boundingBoxWidth) height: \(obs.boundingBoxHeight)"
                    )
                    return false
                }
                // Ignore heavily skewed text (rotated watermarks, vertical labels, etc.)
                if let skew = skewDegrees(for: obs), abs(skew) > profile.maximumSkewDegrees {
                    logger.debug(
                        "OCR: skew excluded \(obs.text, privacy: .public) skew: \(String(format: "%.1f", skew), privacy: .public)°"
                    )
                    return false
                }
                return !profile.shouldExclude(boundingBox: box)
            }
        } else {
            filtered = observations
        }
        let lines = filtered.map { obs -> String in
            let area = obs.boundingBoxWidth * obs.boundingBoxHeight
            return area < Double(profile.parenthesesAreaThreshold) ? "(\(obs.text))" : obs.text
        }
        return lines.joined(separator: "\\N")
    }

    /// Normalized Levenshtein distance between two strings, in 0…1 (0 = identical, 1 = nothing in common).
    /// Operates on Unicode scalars for speed; nil inputs or empty strings are handled gracefully.
    private static func normalizedEditDistance(_ a: String, _ b: String) -> Float {
        if a == b { return 0 }
        if a.isEmpty || b.isEmpty { return 1 }
        let av = Array(a.unicodeScalars)
        let bv = Array(b.unicodeScalars)
        let maxLen = max(av.count, bv.count)
        // Single-row DP — O(|a|·|b|) time, O(|b|) space.
        var row = Array(0...bv.count)
        for i in 1...av.count {
            let prev = row
            row[0] = i
            for j in 1...bv.count {
                row[j] =
                    av[i - 1] == bv[j - 1]
                    ? prev[j - 1]
                    : 1 + min(prev[j - 1], prev[j], row[j - 1])
            }
        }
        return Float(row[bv.count]) / Float(maxLen)
    }

    /// Normalizes near-duplicate consecutive OCR results to the same string so that
    /// `mergeConsecutiveDuplicates` can fold them into a single cue.
    private func collapseTextNearDuplicates(
        _ frameResults: [(Int, String)],
        profile: OCRProfile
    ) -> [(Int, String)] {
        guard !frameResults.isEmpty else { return frameResults }
        var out: [(Int, String)] = []
        out.reserveCapacity(frameResults.count)
        out.append(frameResults[0])
        for i in 1..<frameResults.count {
            let (idx, text) = frameResults[i]
            let prev = out.last!.1
            if Self.normalizedEditDistance(text, prev) < profile.textSimilarityReuseThreshold {
                out.append((idx, prev))
            } else {
                out.append((idx, text))
            }
        }
        return out
    }

    private func mergeConsecutiveDuplicates(
        frameResults: [(Int, String)],
        totalSeconds: Double,
        fps: Int
    ) -> [SubtitleCue] {
        let fpsDouble = Double(fps)
        var cues: [SubtitleCue] = []
        var id = 1
        var i = 0

        while i < frameResults.count {
            let (startFrame, text) = frameResults[i]
            var endFrame = startFrame + 1
            var j = i + 1

            while j < frameResults.count, frameResults[j].1 == text, frameResults[j].0 == endFrame {
                endFrame += 1
                j += 1
            }

            let startMs = Int((Double(startFrame) / fpsDouble) * 1000)
            let endSecondsBound = min(Double(endFrame) / fpsDouble, totalSeconds)
            let endMs = Int(endSecondsBound * 1000)

            let cue = SubtitleCue(
                id: id,
                startTime: startMs,
                endTime: endMs,
                rawText: text,
                plainText: text.replacingOccurrences(of: "\\N", with: "\n"),
                attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
            )
            cues.append(cue)
            id += 1
            i = j
        }

        return cues
    }
}
