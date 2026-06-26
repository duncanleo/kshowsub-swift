import Foundation
import SubtitleKit

public enum PostProcessingCueKind: String, Codable, Sendable {
    case dialogue
    case onScreen
    case unknown
}

public struct PostProcessingInputCue: Codable, Sendable {
    public let index: Int
    public let source: String
    public let kind: PostProcessingCueKind
    public let startTime: Int
    public let endTime: Int
    public let text: String

    public init(
        index: Int,
        source: String,
        kind: PostProcessingCueKind,
        startTime: Int,
        endTime: Int,
        text: String
    ) {
        self.index = index
        self.source = source
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public struct PostProcessingCueOverlap: Codable, Equatable, Sendable {
    public let index: Int
    public let overlaps: [Int]

    public init(index: Int, overlaps: [Int]) {
        self.index = index
        self.overlaps = overlaps
    }
}

public struct PostProcessingBatchContext: Codable, Equatable, Sendable {
    public let dialogueIndexes: [Int]
    public let onScreenIndexes: [Int]
    public let unknownIndexes: [Int]
    public let overlaps: [PostProcessingCueOverlap]

    public init(
        dialogueIndexes: [Int],
        onScreenIndexes: [Int],
        unknownIndexes: [Int],
        overlaps: [PostProcessingCueOverlap]
    ) {
        self.dialogueIndexes = dialogueIndexes
        self.onScreenIndexes = onScreenIndexes
        self.unknownIndexes = unknownIndexes
        self.overlaps = overlaps
    }
}

public struct PostProcessingInputBatch: Codable, Sendable {
    public let cues: [PostProcessingInputCue]
    public let context: PostProcessingBatchContext

    public init(cues: [PostProcessingInputCue], context: PostProcessingBatchContext) {
        self.cues = cues
        self.context = context
    }
}

public struct PostProcessedCue: Codable, Equatable, Sendable {
    public let startTime: Int
    public let endTime: Int
    public let text: String

    public init(startTime: Int, endTime: Int, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public protocol SubtitlePostProcessingProvider: Sendable {
    static var id: String { get }
    static var displayName: String { get }

    var id: String { get }
    var maxPromptCharacters: Int? { get }

    func estimateCost(for batch: PostProcessingInputBatch) -> TranslationCostEstimate
    func postProcess(_ batch: PostProcessingInputBatch) async throws -> [PostProcessedCue]
    static func validatePostProcessingConfiguration(options: [String: String]) throws
}

extension SubtitlePostProcessingProvider {
    public var id: String { Self.id }
    public var maxPromptCharacters: Int? { nil }
    public static func validatePostProcessingConfiguration(options: [String: String]) throws {}
}

public enum SubtitlePostProcessingProviderRegistry {
    typealias Factory = @Sendable (Locale, [String: String]) throws -> any SubtitlePostProcessingProvider

    private static let providers: [String: Factory] = [
        AppleIntelligencePostProcessingProvider.id: { locale, _ in
            try AppleIntelligencePostProcessingProvider(locale: locale)
        },
        OpenAIPostProcessingProvider.id: { locale, opts in
            try OpenAIPostProcessingProvider(
                locale: locale,
                model: opts["openai-model"],
                baseURL: opts["openai-base-url"].flatMap(URL.init(string:)),
                authMode: opts["openai-auth"]
            )
        },
    ]

    public static var availableIDs: [String] { Array(providers.keys).sorted() }

    public static func validateProviderID(_ id: String) throws {
        guard providers[id] != nil else {
            throw PostProcessingError.unknownProvider(id, available: availableIDs)
        }
    }

    public static func validateProviderConfiguration(id: String, options: [String: String] = [:]) throws {
        try validateProviderID(id)
        switch id {
        case AppleIntelligencePostProcessingProvider.id:
            try AppleIntelligencePostProcessingProvider.validatePostProcessingConfiguration(options: options)
        case OpenAIPostProcessingProvider.id:
            try OpenAIPostProcessingProvider.validatePostProcessingConfiguration(options: options)
        default:
            break
        }
    }

    public static func resolve(
        id: String,
        locale: Locale,
        options: [String: String] = [:]
    ) throws -> (any SubtitlePostProcessingProvider)? {
        guard let factory = providers[id] else { return nil }
        return try factory(locale, options)
    }

    public static func resolveOrThrow(
        id: String,
        locale: Locale,
        options: [String: String] = [:]
    ) throws -> any SubtitlePostProcessingProvider {
        guard let provider = try resolve(id: id, locale: locale, options: options) else {
            throw PostProcessingError.unknownProvider(id, available: availableIDs)
        }
        return provider
    }
}

public enum PostProcessingError: LocalizedError {
    case unknownProvider(String, available: [String])
    case invalidResponse(String)
    case contextWindowExceeded
    case unsupportedLanguageOrLocale

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id, let available):
            return "Unknown post-processing provider: '\(id)'. Available: \(available.joined(separator: ", "))"
        case .invalidResponse(let detail):
            return "Post-processing response could not be parsed: \(detail)"
        case .contextWindowExceeded:
            return "Post-processing provider exceeded its model context window."
        case .unsupportedLanguageOrLocale:
            return "Post-processing provider rejected an unsupported language or locale."
        }
    }
}

public struct SubtitlePostProcessor {
    private static let maxPresentationLineCharacters = 42
    private static let maxPresentationCueCharacters = 84

    private let provider: any SubtitlePostProcessingProvider

    public init(provider: any SubtitlePostProcessingProvider) {
        self.provider = provider
    }

    public func postProcess(_ cues: [SubtitleCue]) async throws -> [SubtitleCue] {
        let inputs = cues.enumerated().compactMap { index, cue -> PostProcessingInputCue? in
            let text = cue.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PostProcessingInputCue(
                index: index,
                source: Self.sourceName(for: cue),
                kind: Self.cueKind(for: cue),
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: text
            )
        }
        let inputBatch = Self.batch(from: inputs)

        let estimate = provider.estimateCost(for: inputBatch)
        for line in estimate.lines {
            fputs("\(line)\n", stderr)
        }
        fputs("Post-processing \(inputs.count) cues...\n", stderr)

        let batches = Self.batches(from: inputs, maxPromptCharacters: provider.maxPromptCharacters)
        if batches.count > 1 {
            fputs("Post-processing in \(batches.count) cue window(s) for provider context limits...\n", stderr)
        }

        var outputs: [PostProcessedCue] = []
        for (index, batchCues) in batches.enumerated() {
            if batches.count > 1 {
                fputs("Post-process window \(index + 1)/\(batches.count): \(batchCues.count) cues...\n", stderr)
            }
            outputs.append(contentsOf: try await postProcessBatchWithAdaptiveSplitting(Self.batch(from: batchCues)))
        }

        return Self.presentationOutputs(from: outputs).enumerated().map { offset, output in
            let text = output.text
            let endTime = max(output.endTime, output.startTime + 1)
            return SubtitleCue(
                id: offset + 1,
                startTime: output.startTime,
                endTime: endTime,
                rawText: text.replacingOccurrences(of: "\n", with: "\\N"),
                plainText: text,
                attributes: [SubtitleAttribute(key: "Style", value: "BottomDialogue")]
            )
        }
    }

    private static func presentationOutputs(from outputs: [PostProcessedCue]) -> [PostProcessedCue] {
        outputs.flatMap { output -> [PostProcessedCue] in
            let lines = presentationLines(for: output.text)
                .flatMap(splitLongPresentationLine)
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return [] }

            let groups = presentationLineGroups(from: lines)
            guard groups.count > 1 else {
                return [
                    PostProcessedCue(
                        startTime: output.startTime,
                        endTime: output.endTime,
                        text: groups[0].joined(separator: "\n")
                    )
                ]
            }

            let duration = max(output.endTime - output.startTime, groups.count)
            return groups.enumerated().map { index, group in
                let start = output.startTime + duration * index / groups.count
                let end = output.startTime + duration * (index + 1) / groups.count
                return PostProcessedCue(
                    startTime: start,
                    endTime: max(end, start + 1),
                    text: group.joined(separator: "\n")
                )
            }
        }
    }

    private enum PresentationSegment {
        case dialogue(String)
        case nonDialogue(String)
    }

    private static func presentationLines(for raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "\\N", with: "\n")
            .components(separatedBy: "\n")
            .flatMap { presentationLinesInSingleLine(for: $0) }
    }

    private static func presentationLinesInSingleLine(for rawLine: String) -> [String] {
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

    private static func splitLongPresentationLine(_ line: String) -> [String] {
        let compacted = compactWhitespace(line)
        guard compacted.count > maxPresentationLineCharacters else {
            return compacted.isEmpty ? [] : [compacted]
        }
        if isNonDialogueLine(compacted) {
            return [compacted]
        }

        let punctuationSplits = splitAtStrongPunctuation(compacted)
        if punctuationSplits.count > 1,
            punctuationSplits.allSatisfy({ !$0.isEmpty && $0.count <= maxPresentationCueCharacters })
        {
            return punctuationSplits
        }
        return wrapByWords(compacted, limit: maxPresentationLineCharacters)
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

    private static func presentationLineGroups(from lines: [String]) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []

        for line in lines {
            let candidate = current + [line]
            if !current.isEmpty,
                (candidate.count > 2 || candidate.joined(separator: " ").count > maxPresentationCueCharacters)
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

    private func postProcessBatchWithAdaptiveSplitting(
        _ batch: PostProcessingInputBatch,
        depth: Int = 0
    ) async throws -> [PostProcessedCue] {
        do {
            return try await provider.postProcess(batch)
        } catch {
            guard Self.isRecoverableWindowError(error) else {
                throw error
            }
            guard batch.cues.count > 1 else {
                fputs(
                    "Post-process: provider rejected one cue; preserving it without LLM cleanup.\n",
                    stderr
                )
                return Self.preserve(batch)
            }
            let midpoint = batch.cues.count / 2
            let left = Array(batch.cues[..<midpoint])
            let right = Array(batch.cues[midpoint...])
            let reason = Self.isUnsupportedLanguageError(error) ? "unsupported language/locale" : "context limit"
            fputs(
                "Post-process: provider \(reason) hit; splitting \(batch.cues.count) cues into \(left.count)+\(right.count).\n",
                stderr
            )
            let leftOutputs = try await postProcessBatchWithAdaptiveSplitting(Self.batch(from: left), depth: depth + 1)
            let rightOutputs = try await postProcessBatchWithAdaptiveSplitting(Self.batch(from: right), depth: depth + 1)
            return leftOutputs + rightOutputs
        }
    }

    private static func preserve(_ batch: PostProcessingInputBatch) -> [PostProcessedCue] {
        batch.cues.map { input in
            PostProcessedCue(startTime: input.startTime, endTime: input.endTime, text: input.text)
        }
    }

    private static func batch(from cues: [PostProcessingInputCue]) -> PostProcessingInputBatch {
        let dialogueIndexes = cues.filter { $0.kind == .dialogue }.map(\.index)
        let onScreenIndexes = cues.filter { $0.kind == .onScreen }.map(\.index)
        let unknownIndexes = cues.filter { $0.kind == .unknown }.map(\.index)
        let overlaps = cues.compactMap { cue -> PostProcessingCueOverlap? in
            let overlapping = cues
                .filter { other in
                    other.index != cue.index
                        && max(cue.startTime, other.startTime) < min(cue.endTime, other.endTime)
                }
                .map(\.index)
                .sorted()
            guard !overlapping.isEmpty else { return nil }
            return PostProcessingCueOverlap(index: cue.index, overlaps: overlapping)
        }
        return PostProcessingInputBatch(
            cues: cues,
            context: PostProcessingBatchContext(
                dialogueIndexes: dialogueIndexes,
                onScreenIndexes: onScreenIndexes,
                unknownIndexes: unknownIndexes,
                overlaps: overlaps
            )
        )
    }

    private static func batches(
        from inputs: [PostProcessingInputCue],
        maxPromptCharacters: Int?
    ) -> [[PostProcessingInputCue]] {
        guard let maxPromptCharacters, maxPromptCharacters > 0 else {
            return inputs.isEmpty ? [] : [inputs]
        }

        var batches: [[PostProcessingInputCue]] = []
        var current: [PostProcessingInputCue] = []

        for input in inputs {
            let candidate = current + [input]
            if !current.isEmpty,
                PostProcessingPrompt.userPrompt(batch: batch(from: candidate)).count > maxPromptCharacters
            {
                batches.append(current)
                current = [input]
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    private static func isRecoverableWindowError(_ error: Error) -> Bool {
        isContextWindowError(error) || isUnsupportedLanguageError(error)
    }

    private static func isContextWindowError(_ error: Error) -> Bool {
        if case PostProcessingError.contextWindowExceeded = error {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("context window")
            || message.contains("context length")
            || message.contains("too many tokens")
            || message.contains("maximum context")
    }

    private static func isUnsupportedLanguageError(_ error: Error) -> Bool {
        if case PostProcessingError.unsupportedLanguageOrLocale = error {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("unsupported language")
            || message.contains("unsupported locale")
            || message.contains("language or locale")
    }

    private static func sourceName(for cue: SubtitleCue) -> String {
        switch cueKind(for: cue) {
        case .dialogue:
            return "dialogue"
        case .onScreen:
            return "on-screen"
        case .unknown:
            return "unknown"
        }
    }

    private static func cueKind(for cue: SubtitleCue) -> PostProcessingCueKind {
        if cue.attributes.contains(where: { $0.key == "Style" && $0.value == "TopOCR" }) {
            return .onScreen
        }
        if cue.attributes.contains(where: { $0.key == "Style" && $0.value == "BottomDialogue" }) {
            return .dialogue
        }
        return .unknown
    }
}
