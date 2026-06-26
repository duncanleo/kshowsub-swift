import Foundation
import SubtitleKit

/// Builds an ASS SubtitleDocument with TopOCR and BottomDialogue styles,
/// merging speech and OCR cues sorted by start time.
public enum ASSMerger {
    private struct OCRAvoidanceCandidate {
        let index: Int
        let cue: SubtitleCue
        let normalizedY: Double
    }

    private static let assFormatColumns = [
        "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour",
        "OutlineColour", "BackColour", "Bold", "Italic", "Underline", "StrikeOut",
        "ScaleX", "ScaleY", "Spacing", "Angle", "BorderStyle", "Outline", "Shadow",
        "Alignment", "MarginL", "MarginR", "MarginV", "Encoding",
    ]

    /// TopOCR: beige (#F5F5DC) on black. Positioned OCR cues override alignment with `\pos`.
    private static let topOCRStyleValues: [String] = [
        "TopOCR", "Arial", "48", "&H00DCF5F5", "&H00DCF5F5",
        "&H00000000", "&H00000000", "0", "0", "0", "0",
        "100", "100", "0.00", "0.00", "3", "1.00", "0.00",
        "8", "30", "30", "30", "1",
    ]

    /// BottomDialogue: white on black (alignment 2 = bottom center). MarginV = distance from bottom.
    private static let bottomDialogueStyleValues: [String] = [
        "BottomDialogue", "Arial", "48", "&H00FFFFFF", "&H00FFFFFF",
        "&H00000000", "&H00000000", "0", "0", "0", "0",
        "100", "100", "0.00", "0.00", "3", "1.00", "0.00",
        "2", "30", "30", "30", "1",
    ]

    public static func merge(
        dialogueCues: [SubtitleCue],
        ocrCues: [SubtitleCue],
        playResX: Int = OCRCuePosition.defaultPlayResX,
        playResY: Int = OCRCuePosition.defaultPlayResY,
        enableOCRPositioning: Bool = false,
        ocrPositionTextDirection: OCRCuePosition.TextDirection = .ltr
    ) -> Subtitle {
        merge(
            cues: (dialogueCues + ocrCues).sorted { $0.startTime < $1.startTime },
            playResX: playResX,
            playResY: playResY,
            enableOCRPositioning: enableOCRPositioning,
            ocrPositionTextDirection: ocrPositionTextDirection
        )
    }

    /// Merge pre-sorted cues (e.g. after translation).
    public static func merge(
        cues: [SubtitleCue],
        playResX: Int = OCRCuePosition.defaultPlayResX,
        playResY: Int = OCRCuePosition.defaultPlayResY,
        enableOCRPositioning: Bool = false,
        ocrPositionTextDirection: OCRCuePosition.TextDirection = .ltr
    ) -> Subtitle {
        let topOCRStyle = makeStyle(id: 1, name: "TopOCR", values: topOCRStyleValues)
        let bottomDialogueStyle = makeStyle(
            id: 2, name: "BottomDialogue", values: bottomDialogueStyleValues)

        let allCues = cues
        let dialogueCues = allCues.filter { styleName(for: $0) == "BottomDialogue" }
        let dialogueAvoidanceMinimumYs = dialogueAvoidanceMinimumYs(
            for: allCues,
            dialogueCues: dialogueCues
        )
        var entries: [SubtitleEntry] = [.style(topOCRStyle), .style(bottomDialogueStyle)]
        var id = 1
        for (index, cue) in allCues.enumerated() {
            entries.append(
                .cue(
                    SubtitleCue(
                        id: id,
                        cueIdentifier: cue.cueIdentifier,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        rawText: assText(
                            for: cue,
                            playResX: playResX,
                            playResY: playResY,
                            enableOCRPositioning: enableOCRPositioning,
                            ocrPositionTextDirection: ocrPositionTextDirection,
                            minimumNormalizedY: dialogueAvoidanceMinimumYs[index]
                        ),
                        plainText: cue.plainText,
                        frameRange: cue.frameRange,
                        attributes: cue.attributes
                    )))
            id += 1
        }

        let document = SubtitleDocument(formatName: "ass", entries: entries)
        return Subtitle(document: document, sourceLineEnding: .lf)
    }

    private static func makeStyle(id: Int, name: String, values: [String]) -> SubtitleStyle {
        let fields = zip(assFormatColumns, values).map { SubtitleAttribute(key: $0.0, value: $0.1) }
        return SubtitleStyle(id: id, name: name, fields: fields)
    }

    private static func assText(
        for cue: SubtitleCue,
        playResX: Int,
        playResY: Int,
        enableOCRPositioning: Bool,
        ocrPositionTextDirection: OCRCuePosition.TextDirection,
        minimumNormalizedY: Double?
    ) -> String {
        guard
            enableOCRPositioning,
            styleName(for: cue) == "TopOCR",
            let prefix = OCRCuePosition.assOverridePrefix(
                from: cue.attributes,
                playResX: playResX,
                playResY: playResY,
                textDirection: ocrPositionTextDirection,
                minimumNormalizedY: minimumNormalizedY
            ),
            !cue.rawText.contains("\\pos(")
        else {
            return cue.rawText
        }
        return prefix + cue.rawText
    }

    private static func styleName(for cue: SubtitleCue) -> String? {
        cue.attributes.first { $0.key == "Style" }?.value
    }

    private static func dialogueAvoidanceMinimumYs(
        for cues: [SubtitleCue],
        dialogueCues: [SubtitleCue]
    ) -> [Double?] {
        let candidateLimit = OCRCuePosition.dialogueAvoidanceMinimumY(forLane: 1)
        let candidates = cues.enumerated().compactMap { index, cue -> OCRAvoidanceCandidate? in
            guard
                styleName(for: cue) == "TopOCR",
                let normalizedY = OCRCuePosition.normalizedY(from: cue.attributes),
                normalizedY < candidateLimit,
                dialogueCues.contains(where: { overlaps(cue, $0) })
            else {
                return nil
            }
            return OCRAvoidanceCandidate(index: index, cue: cue, normalizedY: normalizedY)
        }

        var assigned: [(cue: SubtitleCue, lane: Int)] = []
        var minimumYs = Array<Double?>(repeating: nil, count: cues.count)
        for candidate in candidates.sorted(by: compareAvoidanceCandidates) {
            var lane = 0
            while assigned.contains(where: { $0.lane == lane && overlaps(candidate.cue, $0.cue) }) {
                lane += 1
            }
            minimumYs[candidate.index] = OCRCuePosition.dialogueAvoidanceMinimumY(forLane: lane)
            assigned.append((cue: candidate.cue, lane: lane))
        }
        return minimumYs
    }

    private static func compareAvoidanceCandidates(
        _ lhs: OCRAvoidanceCandidate,
        _ rhs: OCRAvoidanceCandidate
    ) -> Bool {
        if lhs.cue.startTime != rhs.cue.startTime {
            return lhs.cue.startTime < rhs.cue.startTime
        }
        if lhs.normalizedY != rhs.normalizedY {
            return lhs.normalizedY < rhs.normalizedY
        }
        return lhs.index < rhs.index
    }

    private static func overlaps(_ lhs: SubtitleCue, _ rhs: SubtitleCue) -> Bool {
        lhs.startTime < rhs.endTime && rhs.startTime < lhs.endTime
    }
}
