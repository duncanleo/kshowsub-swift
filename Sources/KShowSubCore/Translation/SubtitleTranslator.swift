import Foundation
import SubtitleKit

/// Translates subtitle cues using a TranslationProvider.
/// Produces new cues with identical timing and structure but translated text.
public struct SubtitleTranslator {
    private let provider: any TranslationProvider
    /// Number of adjacent subtitle lines to include as context before and after each request.
    public let contextLines: Int

    public init(provider: any TranslationProvider, contextLines: Int = 2) {
        self.provider = provider
        self.contextLines = contextLines
    }

    /// Translate all cues. Deduplicates empty or duplicate text to reduce API calls.
    /// The first occurrence of each unique string determines the context window.
    public func translate(_ cues: [SubtitleCue]) async throws -> [SubtitleCue] {
        let allTexts = cues.map { $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }

        var toTranslate: [(key: String, text: String, cueIndex: Int)] = []
        var seen = Set<String>()

        for (i, cue) in cues.enumerated() {
            let key = allTexts[i]
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            toTranslate.append((key: key, text: cue.plainText, cueIndex: i))
        }

        // Build requests, expanding multi-line cue texts into individual per-line requests.
        // After translation the sub-lines are reassembled with newlines.
        struct LineMapping {
            let requestIndex: Int  // index in toTranslate
            let lineIndex: Int
        }

        var expandedRequests: [TranslationRequest] = []
        var lineMappings: [LineMapping] = []

        for (requestIndex, item) in toTranslate.enumerated() {
            let i = item.cueIndex
            let before = allTexts[max(0, i - contextLines)..<i].filter { !$0.isEmpty }
            let after = allTexts[(i + 1)..<min(cues.count, i + 1 + contextLines)].filter {
                !$0.isEmpty
            }
            let lines = item.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                expandedRequests.append(
                    TranslationRequest(
                        text: line,
                        contextBefore: Array(before),
                        contextAfter: Array(after)
                    )
                )
                lineMappings.append(LineMapping(requestIndex: requestIndex, lineIndex: lineIndex))
            }
        }

        let estimate = provider.estimateCost(for: expandedRequests)
        for line in estimate.lines {
            fputs("\(line)\n", stderr)
        }
        fputs("Translating \(toTranslate.count) unique strings (\(expandedRequests.count) lines)...\n", stderr)
        let translatedLines = try await provider.translate(expandedRequests)

        // Reassemble per-line results back into per-cue strings.
        var linesByRequest = [Int: [(lineIndex: Int, text: String)]]()
        for (expandedIndex, translatedText) in translatedLines.enumerated() {
            let m = lineMappings[expandedIndex]
            linesByRequest[m.requestIndex, default: []].append((m.lineIndex, translatedText))
        }

        var translationMap: [String: String] = [:]
        for (requestIndex, item) in toTranslate.enumerated() {
            if let lines = linesByRequest[requestIndex] {
                let reassembled = lines.sorted { $0.lineIndex < $1.lineIndex }.map(\.text).joined(separator: "\n")
                translationMap[item.key] = reassembled
            } else {
                translationMap[item.key] = item.text
            }
        }

        return cues.map { cue in
            let key = cue.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translatedText =
                key.isEmpty ? cue.plainText : (translationMap[key] ?? cue.plainText)
            let rawForASS = translatedText.replacingOccurrences(of: "\n", with: "\\N")
            return SubtitleCue(
                id: cue.id,
                cueIdentifier: cue.cueIdentifier,
                startTime: cue.startTime,
                endTime: cue.endTime,
                rawText: rawForASS,
                plainText: translatedText,
                frameRange: cue.frameRange,
                attributes: cue.attributes
            )
        }
    }
}
