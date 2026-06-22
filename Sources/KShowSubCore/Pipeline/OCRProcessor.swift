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

public actor OCRProcessor: VideoOCRProcessing {
    private let positionedOverlays: Bool

    public init(positionedOverlays: Bool = false) {
        self.positionedOverlays = positionedOverlays
    }

    private struct PendingOCRFrame: @unchecked Sendable {
        let index: Int
        let image: CGImage
        let fingerprint: [UInt8]?
    }

    private struct OCRFrameText {
        let index: Int
        let text: String
        let position: OCRCuePosition.Normalized?
        let fontHeight: Double?
    }

    private struct ActiveOCRCue {
        let text: String
        let position: OCRCuePosition.Normalized?
        let fontHeight: Double?
        let startFrame: Int
        var endFrame: Int
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
        persistRecords: OCRFrameRecordPersistence? = nil
    ) async throws -> [SubtitleCue] {
        precondition(fps >= 1)
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw OCRProcessorError.noVideoTrack
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let presentationSize = Self.presentationSize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let imageHeight = Double(presentationSize.height)

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
        var frameResults: [OCRFrameText] = cachedRecords.flatMap { record in
            if let obs = record.observations {
                return Self.frameTexts(
                    from: obs,
                    index: record.index,
                    imageHeight: imageHeight,
                    profile: profile,
                    positionedOverlays: positionedOverlays
                )
            } else {
                return record.recognizedText.isEmpty
                    ? []
                    : [
                        OCRFrameText(
                            index: record.index,
                            text: record.recognizedText,
                            position: nil,
                            fontHeight: nil)
                    ]
            }
        }

        if resumeIndex >= frameCount {
            logger.info("OCR: refiltering \(frameCount) cached frames...")
            return mergeFrameTexts(
                frameResults: frameResults,
                totalSeconds: totalSeconds,
                fps: fps,
                profile: profile
            )
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
                frameResults.append(contentsOf:
                    flushedRecords.flatMap { record -> [OCRFrameText] in
                        guard let obs = record.observations else { return [] }
                        return Self.frameTexts(
                            from: obs,
                            index: record.index,
                            imageHeight: imageHeight,
                            profile: profile,
                            positionedOverlays: positionedOverlays
                        )
                    })
                if let persistRecords {
                    try await persistRecords(flushedRecords)
                }
                pendingOCRFrames.removeAll(keepingCapacity: true)

                frameResults.append(contentsOf:
                    Self.frameTexts(
                        from: lastObservations,
                        index: k,
                        imageHeight: imageHeight,
                        profile: profile,
                        positionedOverlays: positionedOverlays
                    )
                )
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
                    frameResults.append(contentsOf:
                        flushedRecords.flatMap { record -> [OCRFrameText] in
                            guard let obs = record.observations else { return [] }
                            return Self.frameTexts(
                                from: obs,
                                index: record.index,
                                imageHeight: imageHeight,
                                profile: profile,
                                positionedOverlays: positionedOverlays
                            )
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
        frameResults.append(contentsOf:
            flushedRecords.flatMap { record -> [OCRFrameText] in
                guard let obs = record.observations else { return [] }
                return Self.frameTexts(
                    from: obs,
                    index: record.index,
                    imageHeight: imageHeight,
                    profile: profile,
                    positionedOverlays: positionedOverlays
                )
            })
        if let persistRecords {
            try await persistRecords(flushedRecords)
        }

        return mergeFrameTexts(
            frameResults: frameResults, totalSeconds: totalSeconds, fps: fps, profile: profile)
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

    private static func presentationSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let transformed = naturalSize.applying(preferredTransform)
        let width = abs(transformed.width) > 0 ? abs(transformed.width) : abs(naturalSize.width)
        let height = abs(transformed.height) > 0 ? abs(transformed.height) : abs(naturalSize.height)
        return CGSize(width: width, height: height)
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

    private static func frameTexts(
        from observations: [OCRTextObservation],
        index: Int,
        imageHeight: Double,
        profile: OCRProfile,
        positionedOverlays: Bool
    ) -> [OCRFrameText] {
        if positionedOverlays {
            return positionedFrameTexts(
                observations, index: index, imageHeight: imageHeight, profile: profile)
        }
        return joinedFrameText(observations, index: index, imageHeight: imageHeight, profile: profile)
    }

    private static func positionedFrameTexts(
        _ observations: [OCRTextObservation],
        index: Int,
        imageHeight: Double,
        profile: OCRProfile
    ) -> [OCRFrameText] {
        let filtered = filteredObservations(observations, imageHeight: imageHeight, profile: profile)
        return filtered.map { obs in
            OCRFrameText(
                index: index,
                text: displayText(for: obs, profile: profile),
                position: OCRCuePosition.normalizedCenter(for: [obs]),
                fontHeight: OCRCuePosition.normalizedFontHeight(for: obs)
            )
        }
    }

    private static func joinedFrameText(
        _ observations: [OCRTextObservation],
        index: Int,
        imageHeight: Double,
        profile: OCRProfile
    ) -> [OCRFrameText] {
        let filtered = filteredObservations(observations, imageHeight: imageHeight, profile: profile)
        let text = filtered.map { displayText(for: $0, profile: profile) }.joined(separator: "\\N")
        guard !text.isEmpty else { return [] }
        return [OCRFrameText(index: index, text: text, position: nil, fontHeight: nil)]
    }

    private static func displayText(for obs: OCRTextObservation, profile: OCRProfile) -> String {
        let area = obs.boundingBoxWidth * obs.boundingBoxHeight
        return area < Double(profile.parenthesesAreaThreshold) ? "(\(obs.text))" : obs.text
    }

    private static func filteredObservations(
        _ observations: [OCRTextObservation],
        imageHeight: Double,
        profile: OCRProfile
    ) -> [OCRTextObservation] {
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
        return filtered
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

    private func mergeFrameTexts(
        frameResults: [OCRFrameText],
        totalSeconds: Double,
        fps: Int,
        profile: OCRProfile
    ) -> [SubtitleCue] {
        if !positionedOverlays {
            return mergeConsecutiveDuplicates(
                frameResults: collapseTextNearDuplicates(frameResults, profile: profile),
                totalSeconds: totalSeconds,
                fps: fps
            )
        }

        let fpsDouble = Double(fps)
        var cues: [SubtitleCue] = []
        var active: [ActiveOCRCue] = []

        let grouped = Dictionary(grouping: frameResults, by: \.index)
        for frameIndex in grouped.keys.sorted() {
            var frameItems = grouped[frameIndex] ?? []
            frameItems.sort {
                switch ($0.position, $1.position) {
                case (let lhs?, let rhs?):
                    if lhs.y == rhs.y { return lhs.x < rhs.x }
                    return lhs.y > rhs.y
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return $0.text < $1.text
                }
            }

            var matchedActiveIndexes = Set<Int>()
            for item in frameItems {
                if let matchIndex = bestActiveMatch(
                    for: item,
                    in: active,
                    matchedActiveIndexes: matchedActiveIndexes,
                    profile: profile
                ) {
                    active[matchIndex].endFrame = frameIndex + 1
                    matchedActiveIndexes.insert(matchIndex)
                } else {
                    active.append(
                        ActiveOCRCue(
                            text: item.text,
                            position: item.position,
                            fontHeight: item.fontHeight,
                            startFrame: frameIndex,
                            endFrame: frameIndex + 1
                        ))
                    matchedActiveIndexes.insert(active.count - 1)
                }
            }

            var stillActive: [ActiveOCRCue] = []
            for cue in active {
                if cue.endFrame <= frameIndex {
                    cues.append(makeCue(from: cue, totalSeconds: totalSeconds, fpsDouble: fpsDouble))
                } else {
                    stillActive.append(cue)
                }
            }
            active = stillActive
        }

        for cue in active {
            cues.append(makeCue(from: cue, totalSeconds: totalSeconds, fpsDouble: fpsDouble))
        }

        return cues
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
            .enumerated()
            .map { index, cue in
                SubtitleCue(
                    id: index + 1,
                    cueIdentifier: cue.cueIdentifier,
                    startTime: cue.startTime,
                    endTime: cue.endTime,
                    rawText: cue.rawText,
                    plainText: cue.plainText,
                    frameRange: cue.frameRange,
                    attributes: cue.attributes
                )
            }
    }

    private func bestActiveMatch(
        for item: OCRFrameText,
        in active: [ActiveOCRCue],
        matchedActiveIndexes: Set<Int>,
        profile: OCRProfile
    ) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, cue) in active.enumerated() {
            guard !matchedActiveIndexes.contains(index),
                cue.endFrame == item.index,
                OCRCuePosition.isNear(cue.position, item.position),
                Self.normalizedEditDistance(cue.text, item.text) < profile.textSimilarityReuseThreshold
            else {
                continue
            }

            let distance = OCRCuePosition.distance(cue.position, item.position)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func makeCue(
        from active: ActiveOCRCue,
        totalSeconds: Double,
        fpsDouble: Double
    ) -> SubtitleCue {
        let startMs = Int((Double(active.startFrame) / fpsDouble) * 1000)
        let endSecondsBound = min(Double(active.endFrame) / fpsDouble, totalSeconds)
        let endMs = Int(endSecondsBound * 1000)

        return SubtitleCue(
            id: 0,
            startTime: startMs,
            endTime: endMs,
            rawText: active.text,
            plainText: active.text.replacingOccurrences(of: "\\N", with: "\n"),
            attributes: [SubtitleAttribute(key: "Style", value: "TopOCR")]
                + OCRCuePosition.attributes(for: active.position, fontHeight: active.fontHeight)
        )
    }

    private func collapseTextNearDuplicates(
        _ frameResults: [OCRFrameText],
        profile: OCRProfile
    ) -> [OCRFrameText] {
        guard !frameResults.isEmpty else { return frameResults }
        var out: [OCRFrameText] = []
        out.reserveCapacity(frameResults.count)
        out.append(frameResults[0])
        for i in 1..<frameResults.count {
            let result = frameResults[i]
            let prev = out.last!
            if Self.normalizedEditDistance(result.text, prev.text) < profile.textSimilarityReuseThreshold {
                out.append(
                    OCRFrameText(
                        index: result.index,
                        text: prev.text,
                        position: nil,
                        fontHeight: nil
                    ))
            } else {
                out.append(result)
            }
        }
        return out
    }

    private func mergeConsecutiveDuplicates(
        frameResults: [OCRFrameText],
        totalSeconds: Double,
        fps: Int
    ) -> [SubtitleCue] {
        let fpsDouble = Double(fps)
        var cues: [SubtitleCue] = []
        var id = 1
        var i = 0

        while i < frameResults.count {
            let result = frameResults[i]
            let startFrame = result.index
            let text = result.text
            var endFrame = startFrame + 1
            var j = i + 1

            while j < frameResults.count,
                frameResults[j].text == text,
                frameResults[j].index == endFrame
            {
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
