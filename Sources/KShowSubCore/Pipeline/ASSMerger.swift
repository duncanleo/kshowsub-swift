import Foundation
import SubtitleKit

/// Builds an ASS SubtitleDocument with TopOCR and BottomDialogue styles,
/// merging speech and OCR cues sorted by start time.
public enum ASSMerger {
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
        playResY: Int = OCRCuePosition.defaultPlayResY
    ) -> Subtitle {
        merge(
            cues: (dialogueCues + ocrCues).sorted { $0.startTime < $1.startTime },
            playResX: playResX,
            playResY: playResY
        )
    }

    /// Merge pre-sorted cues (e.g. after translation).
    public static func merge(
        cues: [SubtitleCue],
        playResX: Int = OCRCuePosition.defaultPlayResX,
        playResY: Int = OCRCuePosition.defaultPlayResY
    ) -> Subtitle {
        let topOCRStyle = makeStyle(id: 1, name: "TopOCR", values: topOCRStyleValues)
        let bottomDialogueStyle = makeStyle(
            id: 2, name: "BottomDialogue", values: bottomDialogueStyleValues)

        let allCues = cues
        var entries: [SubtitleEntry] = [.style(topOCRStyle), .style(bottomDialogueStyle)]
        var id = 1
        for cue in allCues {
            entries.append(
                .cue(
                    SubtitleCue(
                        id: id,
                        cueIdentifier: cue.cueIdentifier,
                        startTime: cue.startTime,
                        endTime: cue.endTime,
                        rawText: assText(for: cue, playResX: playResX, playResY: playResY),
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

    private static func assText(for cue: SubtitleCue, playResX: Int, playResY: Int) -> String {
        guard
            let prefix = OCRCuePosition.assOverridePrefix(
                from: cue.attributes,
                playResX: playResX,
                playResY: playResY
            ),
            !cue.rawText.contains("\\pos(")
        else {
            return cue.rawText
        }
        return prefix + cue.rawText
    }
}
