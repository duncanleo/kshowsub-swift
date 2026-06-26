import Foundation

enum PostProcessingResponseParser {
    private struct ResponseCue: Decodable {
        let startTime: Int?
        let endTime: Int?
        let text: String

        private enum CodingKeys: String, CodingKey {
            case startTime
            case startMs
            case start_ms
            case start
            case begin
            case endTime
            case endMs
            case end_ms
            case end
            case stop
            case text
            case line
            case subtitle
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            startTime =
                Self.decodeMilliseconds(from: container, keys: [.startTime, .startMs, .start_ms, .start, .begin])
            endTime =
                Self.decodeMilliseconds(from: container, keys: [.endTime, .endMs, .end_ms, .end, .stop])
            text =
                (try? container.decode(String.self, forKey: .text))
                ?? (try? container.decode(String.self, forKey: .line))
                ?? (try? container.decode(String.self, forKey: .subtitle))
                ?? (try? container.decode(String.self, forKey: .content))
                ?? ""
        }

        private static func decodeMilliseconds(
            from container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> Int? {
            for key in keys {
                if let value = try? container.decode(Double.self, forKey: key) {
                    return milliseconds(from: value, key: key)
                }
                if let value = try? container.decode(Int.self, forKey: key) {
                    return milliseconds(from: Double(value), key: key)
                }
                if let value = try? container.decode(String.self, forKey: key),
                    let parsed = milliseconds(from: value, key: key)
                {
                    return parsed
                }
            }
            return nil
        }

        private static func milliseconds(from value: Double, key: CodingKeys) -> Int {
            let keyName = key.rawValue.lowercased()
            if keyName.contains("ms") || keyName.contains("time") || value > 10_000 {
                return Int(value.rounded())
            }
            return Int((value * 1_000).rounded())
        }

        private static func milliseconds(from raw: String, key: CodingKeys) -> Int? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) {
                return milliseconds(from: Double(int), key: key)
            }
            if let double = Double(trimmed) {
                return milliseconds(from: double, key: key)
            }
            return milliseconds(fromTimecode: trimmed)
        }

        private static func milliseconds(fromTimecode raw: String) -> Int? {
            let normalized = raw.replacingOccurrences(of: ",", with: ".")
            let parts = normalized.split(separator: ":").map(String.init)
            guard parts.count == 2 || parts.count == 3 else { return nil }

            let hours: Double
            let minutes: Double
            let seconds: Double
            if parts.count == 3 {
                guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
                    return nil
                }
                hours = h
                minutes = m
                seconds = s
            } else {
                guard let m = Double(parts[0]), let s = Double(parts[1]) else {
                    return nil
                }
                hours = 0
                minutes = m
                seconds = s
            }
            return Int(((hours * 3_600 + minutes * 60 + seconds) * 1_000).rounded())
        }
    }

    private struct ResponseObject: Decodable {
        let cues: [ResponseCue]?
        let subtitles: [ResponseCue]?
        let subtitleCues: [ResponseCue]?

        var allCues: [ResponseCue] {
            cues ?? subtitles ?? subtitleCues ?? []
        }
    }

    static func parse(_ raw: String) throws -> [PostProcessedCue] {
        let trimmed = normalizeQuotes(
            extractJSON(from: stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
                ?? stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        guard let data = trimmed.data(using: .utf8) else {
            throw PostProcessingError.invalidResponse("Response was not valid UTF-8.")
        }

        let decoder = JSONDecoder()
        let responseCues: [ResponseCue]
        if let object = try? decoder.decode(ResponseObject.self, from: data) {
            responseCues = object.allCues
        } else if let array = try? decoder.decode([ResponseCue].self, from: data) {
            responseCues = array
        } else {
            throw PostProcessingError.invalidResponse(
                "Expected JSON object with a cues array. Raw response prefix: \(rawPrefix(raw))"
            )
        }

        let normalizedResponseCues = responseCues
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                (lhs.startTime ?? Int.max) < (rhs.startTime ?? Int.max)
            }
        let cues = normalizedResponseCues.enumerated().compactMap { index, cue -> PostProcessedCue? in
            guard let start = cue.startTime else { return nil }
            let inferredEnd =
                cue.endTime
                ?? normalizedResponseCues[(index + 1)..<normalizedResponseCues.count]
                    .compactMap(\.startTime)
                    .first
                ?? start + 2_000
            return PostProcessedCue(
                startTime: start,
                endTime: max(inferredEnd, start + 1),
                text: cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        .sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }

        guard !cues.isEmpty || responseCues.isEmpty else {
            throw PostProcessingError.invalidResponse(
                "No valid cues with start/end times were returned. Raw response prefix: \(rawPrefix(raw))"
            )
        }
        return cues
    }

    private static func stripCodeFence(_ raw: String) -> String {
        var lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard lines.count >= 3,
            lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true,
            lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true
        else {
            return raw
        }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    private static func extractJSON(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "{" || text.first == "[" {
            return text
        }

        let candidates: [(start: String.Index, opener: Character, closer: Character)] = [
            text.firstIndex(of: "{").map { ($0, Character("{"), Character("}")) },
            text.firstIndex(of: "[").map { ($0, Character("["), Character("]")) },
        ].compactMap { $0 }
            .sorted { $0.start < $1.start }

        for candidate in candidates {
            if let end = balancedEndIndex(
                in: text,
                start: candidate.start,
                opener: candidate.opener,
                closer: candidate.closer
            ) {
                return String(text[candidate.start...end])
            }
        }
        return nil
    }

    private static func balancedEndIndex(
        in text: String,
        start: String.Index,
        opener: Character,
        closer: Character
    ) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else if char == "\"" {
                inString = true
            } else if char == opener {
                depth += 1
            } else if char == closer {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func normalizeQuotes(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    private static func rawPrefix(_ raw: String) -> String {
        let normalized =
            raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
        return String(normalized.prefix(240))
    }
}
