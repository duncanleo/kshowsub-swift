import Foundation
import SubtitleKit

enum SubtitlePresentationNormalizer {
    private static let maxLineCharacters = 42
    private static let maxCueCharacters = 84

    static func outputs(from outputs: [PostProcessedCue]) -> [PostProcessedCue] {
        outputs.flatMap { output -> [PostProcessedCue] in
            splitCueText(output.text, startTime: output.startTime, endTime: output.endTime).map { segment in
                PostProcessedCue(
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: segment.text
                )
            }
        }
    }

    static func cues(from cue: SubtitleCue) -> [SubtitleCue] {
        splitCueText(cue.plainText, startTime: cue.startTime, endTime: cue.endTime).map { segment in
            let rawText = segment.text.replacingOccurrences(of: "\n", with: "\\N")
            return SubtitleCue(
                id: cue.id,
                cueIdentifier: cue.cueIdentifier,
                startTime: segment.startTime,
                endTime: segment.endTime,
                rawText: rawText,
                plainText: segment.text,
                frameRange: cue.frameRange,
                attributes: cue.attributes
            )
        }
    }

    static func lines(for raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\\N", with: "\n")
            .components(separatedBy: "\n")
            .flatMap { linesInSingleLine(for: $0) }
            .flatMap(splitLongLine)
            .filter { !$0.isEmpty }
    }

    private struct TextSegment {
        let startTime: Int
        let endTime: Int
        let text: String
    }

    private enum PresentationSegment {
        case dialogue(String)
        case nonDialogue(String)
    }

    private static func splitCueText(_ raw: String, startTime: Int, endTime: Int) -> [TextSegment] {
        let normalizedLines = lines(for: raw)
        guard !normalizedLines.isEmpty else { return [] }

        let groups = lineGroups(from: normalizedLines)
        guard groups.count > 1 else {
            return [TextSegment(startTime: startTime, endTime: endTime, text: groups[0].joined(separator: "\n"))]
        }

        let duration = max(endTime - startTime, groups.count)
        return groups.enumerated().map { index, group in
            let start = startTime + duration * index / groups.count
            let end = startTime + duration * (index + 1) / groups.count
            return TextSegment(
                startTime: start,
                endTime: max(end, start + 1),
                text: group.joined(separator: "\n")
            )
        }
    }

    private static func linesInSingleLine(for rawLine: String) -> [String] {
        let segments = presentationSegments(in: rawLine)
        let hasDialogue = segments.contains { segment in
            if case .dialogue(let text) = segment {
                return !compactWhitespace(text).isEmpty
            }
            return false
        }
        let hasNonDialogue = segments.contains { segment in
            if case .nonDialogue = segment { return true }
            return false
        }
        guard hasDialogue, hasNonDialogue else {
            let compacted = compactWhitespace(rawLine)
            return compacted.isEmpty ? [] : [compacted]
        }

        var lines: [String] = []
        var dialogueParts: [String] = []

        func flushDialogue() {
            let dialogue = compactWhitespace(dialogueParts.joined(separator: " "))
            if !dialogue.isEmpty {
                lines.append(dialogue)
            }
            dialogueParts.removeAll(keepingCapacity: true)
        }

        for segment in segments {
            switch segment {
            case .dialogue(let text):
                let compacted = compactWhitespace(text)
                if !compacted.isEmpty {
                    dialogueParts.append(compacted)
                }
            case .nonDialogue(let text):
                flushDialogue()
                let compacted = compactWhitespace(text)
                if !compacted.isEmpty {
                    lines.append(compacted)
                }
            }
        }
        flushDialogue()
        return lines
    }

    private static func presentationSegments(in line: String) -> [PresentationSegment] {
        var segments: [PresentationSegment] = []
        var cursor = line.startIndex

        while cursor < line.endIndex {
            guard let open = line[cursor...].firstIndex(of: "("),
                let close = line[line.index(after: open)...].firstIndex(of: ")")
            else {
                segments.append(.dialogue(String(line[cursor...])))
                break
            }

            if open > cursor {
                segments.append(.dialogue(String(line[cursor..<open])))
            }
            let end = parentheticalEndIncludingTrailingPunctuation(in: line, close: close)
            segments.append(.nonDialogue(String(line[open...end])))
            cursor = line.index(after: end)
        }
        return segments
    }

    private static func parentheticalEndIncludingTrailingPunctuation(
        in line: String,
        close: String.Index
    ) -> String.Index {
        var end = close
        var cursor = line.index(after: close)
        while cursor < line.endIndex {
            let char = line[cursor]
            if char.isWhitespace {
                break
            }
            if ".!?,;:".contains(char) {
                end = cursor
                cursor = line.index(after: cursor)
                continue
            }
            break
        }
        return end
    }

    private static func splitLongLine(_ line: String) -> [String] {
        let compacted = compactWhitespace(line)
        guard compacted.count > maxLineCharacters else {
            return compacted.isEmpty ? [] : [compacted]
        }
        if isNonDialogueLine(compacted) {
            return [compacted]
        }

        let punctuationSplits = splitAtStrongPunctuation(compacted)
        if punctuationSplits.count > 1,
            punctuationSplits.allSatisfy({ !$0.isEmpty && $0.count <= maxCueCharacters })
        {
            return punctuationSplits
        }
        return wrapByWords(compacted, limit: maxLineCharacters)
    }

    private static func splitAtStrongPunctuation(_ line: String) -> [String] {
        var parts: [String] = []
        var start = line.startIndex
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if ".?!;".contains(char) {
                let end = line.index(after: index)
                let part = compactWhitespace(String(line[start..<end]))
                if !part.isEmpty {
                    parts.append(part)
                }
                start = end
            }
            index = line.index(after: index)
        }
        let tail = compactWhitespace(String(line[start..<line.endIndex]))
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts.count > 1 ? parts : [line]
    }

    private static func wrapByWords(_ line: String, limit: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in line.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if !current.isEmpty, candidate.count > limit {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func lineGroups(from lines: [String]) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []

        for line in lines {
            let candidate = current + [line]
            if !current.isEmpty,
                (candidate.count > 2 || candidate.joined(separator: " ").count > maxCueCharacters)
            {
                groups.append(current)
                current = [line]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func isNonDialogueLine(_ line: String) -> Bool {
        line.hasPrefix("(") && (line.hasSuffix(")") || line.hasSuffix(").") || line.hasSuffix("!)"))
    }

    private static func compactWhitespace(_ raw: String) -> String {
        raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
