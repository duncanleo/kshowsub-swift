import Foundation
import SubtitleKit

/// Merges word-by-word speech cues into readable phrases.
///
/// Apple's Speech framework returns one cue per word. This processor combines consecutive
/// words into shorter phrases than a full two-line cap, inserts explicit line breaks so two-line
/// cues balance across lines, and respects max duration and pause-based splits.
public struct SpeechCueMerger {
    private let locale: Locale
    private let maxCharactersPerCue: Int
    private let maxCharactersPerLine: Int
    private let wordSeparator: String
    private let pauseThresholdMs: Int
    private let maxDurationMs: Int
    private let minDurationMs: Int

    /// Creates a locale-aware merger. Parameters are derived from the locale when not specified.
    /// - Parameters:
    ///   - locale: Locale for language-specific limits (chars/line, word separator).
    ///   - maxCharactersPerCue: Override max chars per cue (defaults are tighter than full two-line caps).
    ///   - maxCharactersPerLine: Soft wrap target per line; explicit `\\N` breaks are inserted for readability.
    ///   - wordSeparator: Override separator when joining words (default: " " for Latin/Korean, "" for CJK).
    ///   - pauseThresholdMs: Gap in ms that triggers a new phrase (default: 600).
    ///   - maxDurationMs: Max duration per cue in ms (default: 7000).
    ///   - minDurationMs: Min duration per cue in ms (default: 833).
    public init(
        locale: Locale = .init(identifier: "en-US"),
        maxCharactersPerCue: Int? = nil,
        maxCharactersPerLine: Int? = nil,
        wordSeparator: String? = nil,
        pauseThresholdMs: Int = 600,
        maxDurationMs: Int = 7000,
        minDurationMs: Int = 833
    ) {
        self.locale = locale
        let config = Self.config(for: locale)
        self.maxCharactersPerLine = maxCharactersPerLine ?? config.maxCharactersPerLine
        self.maxCharactersPerCue = maxCharactersPerCue ?? config.maxCharactersPerCue
        self.wordSeparator = wordSeparator ?? config.wordSeparator
        self.pauseThresholdMs = pauseThresholdMs
        self.maxDurationMs = maxDurationMs
        self.minDurationMs = minDurationMs
    }

    /// Locale-specific defaults: shorter phrases than a full 2× line cap, with wrap targets per line.
    private static func config(for locale: Locale) -> (
        maxCharactersPerCue: Int,
        maxCharactersPerLine: Int,
        wordSeparator: String
    ) {
        let lang = locale.language.languageCode?.identifier.lowercased() ?? ""
        let id = locale.identifier.lowercased()
        switch true {
        case lang == "ko" || id.hasPrefix("ko"):
            // ~18 chars/line target, ~36 per cue (two shorter lines).
            return (36, 18, " ")
        case lang == "zh" || id.hasPrefix("zh"):
            return (36, 18, "")
        case lang == "ja" || id.hasPrefix("ja"):
            return (36, 18, "")
        case lang == "ar" || id.hasPrefix("ar"):
            return (52, 40, " ")
        default:
            // Latin: aim below typical 42/line × 2; split cues earlier so blocks feel lighter.
            return (52, 36, " ")
        }
    }

    /// Merge consecutive dialogue cues into readable phrases.
    /// - Parameter cues: Word-by-word cues from speech transcription (same style).
    /// - Returns: Merged cues suitable for display.
    public func merge(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }

        var merged: [SubtitleCue] = []
        var currentBatch: [SubtitleCue] = [cues[0]]
        var nextId = 1

        for i in 1 ..< cues.count {
            let prev = cues[i - 1]
            let curr = cues[i]
            let gapMs = curr.startTime - prev.endTime

            let combined = combinedPlainText(of: currentBatch)
            let nextText = wordSeparator.isEmpty ? (combined + curr.plainText) : (combined + wordSeparator + curr.plainText)
            let wouldExceedChars = nextText.count > maxCharactersPerCue
            let wouldExceedDuration = (curr.endTime - currentBatch[0].startTime) > maxDurationMs
            let isPause = gapMs >= pauseThresholdMs

            if wouldExceedChars || wouldExceedDuration || isPause {
                merged.append(makeMergedCue(from: currentBatch, id: nextId))
                nextId += 1
                currentBatch = [curr]
            } else {
                currentBatch.append(curr)
            }
        }

        if !currentBatch.isEmpty {
            merged.append(makeMergedCue(from: currentBatch, id: nextId))
        }

        return merged
    }

    private func combinedPlainText(of cues: [SubtitleCue]) -> String {
        cues.map(\.plainText).joined(separator: wordSeparator)
    }

    private func makeMergedCue(from cues: [SubtitleCue], id: Int) -> SubtitleCue {
        let first = cues[0]
        let last = cues[cues.count - 1]
        let joined = cues.map(\.plainText).joined(separator: wordSeparator)
        let plainText = wrapForSubtitle(joined)
        let rawText = plainText.replacingOccurrences(of: "\n", with: "\\N")

        return SubtitleCue(
            id: id,
            cueIdentifier: first.cueIdentifier,
            startTime: first.startTime,
            endTime: last.endTime,
            rawText: rawText,
            plainText: plainText,
            frameRange: first.frameRange,
            attributes: first.attributes
        )
    }

    /// Inserts line breaks at word or character boundaries so each line stays near `maxCharactersPerLine`.
    private func wrapForSubtitle(_ text: String) -> String {
        guard text.count > maxCharactersPerLine else { return text }
        if wordSeparator.isEmpty {
            return wrapCJK(text, lineLimit: maxCharactersPerLine)
        }
        return wrapSpaced(text, lineLimit: maxCharactersPerLine)
    }

    /// CJK: split into at most two lines of `lineLimit` characters each (cue length is capped upstream).
    private func wrapCJK(_ text: String, lineLimit: Int) -> String {
        guard text.count > lineLimit else { return text }
        let first = String(text.prefix(lineLimit))
        let rest = String(text.dropFirst(lineLimit))
        return first + "\n" + rest
    }

    /// Space-separated languages: pick a space so both lines stay near `lineLimit` (not one long + one short wrap).
    private func wrapSpaced(_ text: String, lineLimit: Int) -> String {
        guard text.count > lineLimit else { return text }
        let spaceOffsets: [Int] = text.enumerated().compactMap { $0.element == " " ? $0.offset : nil }
        guard !spaceOffsets.isEmpty else {
            let idx = text.index(text.startIndex, offsetBy: lineLimit)
            return String(text[..<idx]) + "\n" + String(text[idx...])
        }

        let total = text.count
        let mid = total / 2
        // Prefer breaks where each side fits in one line; otherwise closest to center.
        let candidates = spaceOffsets.filter { offset in
            let leftLen = offset
            let rightLen = total - offset - 1
            return leftLen <= lineLimit && rightLen <= lineLimit
        }
        let splitOffset: Int
        if let best = candidates.min(by: { abs($0 - mid) < abs($1 - mid) }) {
            splitOffset = best
        } else if let best = spaceOffsets.min(by: { abs($0 - mid) < abs($1 - mid) }) {
            splitOffset = best
        } else {
            return text
        }

        let splitIndex = text.index(text.startIndex, offsetBy: splitOffset)
        let line1 = String(text[..<splitIndex])
        let afterSpace = text.index(after: splitIndex)
        let line2 = String(text[afterSpace...])
        return line1 + "\n" + line2
    }
}
