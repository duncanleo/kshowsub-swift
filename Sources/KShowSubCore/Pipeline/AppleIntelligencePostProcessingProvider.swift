import Foundation
import FoundationModels

struct AppleIntelligencePostProcessingProvider: SubtitlePostProcessingProvider, Sendable {
    static let id = "apple-intelligence"
    static let displayName = "Apple Intelligence"
    let maxPromptCharacters: Int? = 1_200

    private let locale: Locale
    private let model: SystemLanguageModel

    static func validatePostProcessingConfiguration(options: [String: String]) throws {
        _ = options
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        try requireAvailability(of: model)
    }

    private static func requireAvailability(of model: SystemLanguageModel) throws {
        if case .unavailable(let reason) = model.availability {
            switch reason {
            case .deviceNotEligible:
                throw AppleIntelligenceError.deviceNotEligible
            case .appleIntelligenceNotEnabled:
                throw AppleIntelligenceError.notEnabled
            case .modelNotReady:
                throw AppleIntelligenceError.modelNotReady
            default:
                throw AppleIntelligenceError.other(String(describing: reason))
            }
        }
    }

    init(locale: Locale) throws {
        self.locale = locale
        let created = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        try Self.requireAvailability(of: created)
        model = created
    }

    func estimateCost(for cues: [PostProcessingInputCue]) -> TranslationCostEstimate {
        TranslationCostEstimate(
            estimatedUSD: 0,
            lines: [
                "Estimated API cost: $0 (on-device Apple Intelligence).",
                "Uses small prompt windows for Apple Intelligence's 4k context limit.",
            ]
        )
    }

    func postProcess(_ cues: [PostProcessingInputCue]) async throws -> [PostProcessedCue] {
        guard !cues.isEmpty else { return [] }
        let session = LanguageModelSession(
            model: model,
            instructions: PostProcessingPrompt.systemPrompt(
                locale: locale,
                profile: .appleIntelligence
            )
        )
        let raw: String
        do {
            let response = try await session.respond(to: PostProcessingPrompt.userPrompt(cues: cues))
            raw = try response.rawContent.value(String.self)
        } catch {
            if isContextWindowError(error) {
                throw PostProcessingError.contextWindowExceeded
            }
            if isUnsupportedLanguageError(error) {
                throw PostProcessingError.unsupportedLanguageOrLocale
            }
            throw error
        }
        do {
            return try PostProcessingResponseParser.parse(raw)
        } catch {
            let retryPrompt = Self.repairPrompt(for: raw)
            guard retryPrompt.count <= 1_200 else {
                throw error
            }
            let retryResponse = try await session.respond(
                to: retryPrompt
            )
            let retryRaw = try retryResponse.rawContent.value(String.self)
            return try PostProcessingResponseParser.parse(retryRaw)
        }
    }

    private static func repairPrompt(for raw: String) -> String {
        let clipped = String(raw.prefix(900))
        return """
        Return valid JSON only:
        {"cues":[{"startTime":0,"endTime":1000,"text":"..."}]}

        \(clipped)
        """
    }

    private func isContextWindowError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("context window")
            || message.contains("context length")
            || message.contains("too many tokens")
            || message.contains("maximum context")
    }

    private func isUnsupportedLanguageError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("unsupported language")
            || message.contains("unsupported locale")
            || message.contains("language or locale")
    }
}
