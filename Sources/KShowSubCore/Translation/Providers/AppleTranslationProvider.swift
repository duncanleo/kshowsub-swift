import Foundation
import Translation

/// Translation provider using Apple's Translation framework (on-device, no API key required).
/// Requires macOS 15+ with translation models installed for the requested language pair.
struct AppleTranslationProvider: TranslationProvider, Sendable {
    static let id = "apple-translation"
    static let displayName = "Apple Translation"

    private let sourceLanguage: Locale.Language
    private let targetLanguage: Locale.Language

    static func validateTranslationConfiguration(options: [String: String]) throws {
        // No API keys or special config needed; language pair availability
        // is checked asynchronously at translate time.
    }

    init(sourceLocale: Locale, targetLocale: Locale) {
        sourceLanguage = sourceLocale.language
        targetLanguage = targetLocale.language
    }

    func estimateCost(for requests: [TranslationRequest]) -> TranslationCostEstimate {
        guard !requests.isEmpty else {
            return TranslationCostEstimate(
                estimatedUSD: 0,
                lines: ["Estimated API cost: $0 (nothing to translate)."]
            )
        }
        return TranslationCostEstimate(
            estimatedUSD: 0,
            lines: [
                "Estimated API cost: $0 (on-device Apple Translation).",
                "\(requests.count) unique string(s) to translate.",
            ]
        )
    }

    func translate(_ requests: [TranslationRequest]) async throws -> [String] {
        guard !requests.isEmpty else { return [] }

        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)

        let src =
            sourceLanguage.languageCode?.identifier
            ?? String(sourceLanguage.minimalIdentifier.prefix(2))
        let tgt =
            targetLanguage.languageCode?.identifier
            ?? String(targetLanguage.minimalIdentifier.prefix(2))

        switch status {
        case .unsupported:
            throw AppleTranslationError.unsupportedLanguagePair(source: src, target: tgt)
        case .supported:
            // Models aren't installed. prepareTranslation() requires a UI context to trigger
            // the download sheet, which isn't available in a CLI tool.
            throw AppleTranslationError.modelsNotInstalled(source: src, target: tgt)
        default:
            break
        }

        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        let sessionRequests = requests.enumerated().map { idx, req in
            TranslationSession.Request(sourceText: req.text, clientIdentifier: String(idx))
        }

        let responses = try await session.translations(from: sessionRequests)

        var results = Array(repeating: "", count: requests.count)
        for response in responses {
            guard let idStr = response.clientIdentifier, let idx = Int(idStr) else { continue }
            results[idx] = response.targetText
        }
        return results
    }
}

enum AppleTranslationError: LocalizedError {
    case unsupportedLanguagePair(source: String, target: String)
    case modelsNotInstalled(source: String, target: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguagePair(let src, let tgt):
            return
                "Apple Translation does not support '\(src)' → '\(tgt)'."
        case .modelsNotInstalled(let src, let tgt):
            return
                "Apple Translation models for '\(src)' → '\(tgt)' are not installed. "
                + "Go to System Settings → Language & Region → Translation Languages "
                + "and add the required languages, then retry."
        }
    }
}
