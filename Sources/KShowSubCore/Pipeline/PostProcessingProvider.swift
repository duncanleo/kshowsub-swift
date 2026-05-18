import Foundation
import SubtitleKit

public struct PostProcessingInputCue: Codable, Sendable {
    public let index: Int
    public let source: String
    public let startTime: Int
    public let endTime: Int
    public let text: String

    public init(index: Int, source: String, startTime: Int, endTime: Int, text: String) {
        self.index = index
        self.source = source
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
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

    func estimateCost(for cues: [PostProcessingInputCue]) -> TranslationCostEstimate
    func postProcess(_ cues: [PostProcessingInputCue]) async throws -> [PostProcessedCue]
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
                startTime: cue.startTime,
                endTime: cue.endTime,
                text: text
            )
        }

        let estimate = provider.estimateCost(for: inputs)
        for line in estimate.lines {
            fputs("\(line)\n", stderr)
        }
        fputs("Post-processing \(inputs.count) cues...\n", stderr)

        let batches = Self.batches(from: inputs, maxPromptCharacters: provider.maxPromptCharacters)
        if batches.count > 1 {
            fputs("Post-processing in \(batches.count) cue window(s) for provider context limits...\n", stderr)
        }

        var outputs: [PostProcessedCue] = []
        for (index, batch) in batches.enumerated() {
            if batches.count > 1 {
                fputs("Post-process window \(index + 1)/\(batches.count): \(batch.count) cues...\n", stderr)
            }
            outputs.append(contentsOf: try await postProcessBatchWithAdaptiveSplitting(batch))
        }

        return outputs.enumerated().map { offset, output in
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func postProcessBatchWithAdaptiveSplitting(
        _ batch: [PostProcessingInputCue],
        depth: Int = 0
    ) async throws -> [PostProcessedCue] {
        do {
            return try await provider.postProcess(batch)
        } catch {
            guard Self.isRecoverableWindowError(error) else {
                throw error
            }
            guard batch.count > 1 else {
                fputs(
                    "Post-process: provider rejected one cue; preserving it without LLM cleanup.\n",
                    stderr
                )
                return Self.preserve(batch)
            }
            let midpoint = batch.count / 2
            let left = Array(batch[..<midpoint])
            let right = Array(batch[midpoint...])
            let reason = Self.isUnsupportedLanguageError(error) ? "unsupported language/locale" : "context limit"
            fputs(
                "Post-process: provider \(reason) hit; splitting \(batch.count) cues into \(left.count)+\(right.count).\n",
                stderr
            )
            let leftOutputs = try await postProcessBatchWithAdaptiveSplitting(left, depth: depth + 1)
            let rightOutputs = try await postProcessBatchWithAdaptiveSplitting(right, depth: depth + 1)
            return leftOutputs + rightOutputs
        }
    }

    private static func preserve(_ batch: [PostProcessingInputCue]) -> [PostProcessedCue] {
        batch.map { input in
            PostProcessedCue(startTime: input.startTime, endTime: input.endTime, text: input.text)
        }
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
                PostProcessingPrompt.userPrompt(cues: candidate).count > maxPromptCharacters
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
        if cue.attributes.contains(where: { $0.key == "Style" && $0.value == "TopOCR" }) {
            return "ocr"
        }
        if cue.attributes.contains(where: { $0.key == "Style" && $0.value == "BottomDialogue" }) {
            return "speech"
        }
        return "unknown"
    }
}
