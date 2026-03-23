import Foundation

/// A single translation job, optionally annotated with surrounding subtitle lines for context.
/// Providers that support context (e.g. OpenAI Batch) may use `contextBefore`/`contextAfter`
/// to improve translation quality. Providers that don't support context ignore them.
public struct TranslationRequest: Sendable {
    /// The subtitle text to translate.
    public let text: String
    /// Lines immediately preceding this subtitle in the sequence (oldest first).
    public let contextBefore: [String]
    /// Lines immediately following this subtitle in the sequence (earliest first).
    public let contextAfter: [String]

    public init(text: String, contextBefore: [String] = [], contextAfter: [String] = []) {
        self.text = text
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

/// Abstract interface for subtitle translation. Implementations may use Apple Intelligence,
/// cloud APIs (Google, DeepL, etc.), or other backends.
public protocol TranslationProvider: Sendable {
    /// Unique identifier for CLI selection (e.g. "apple-intelligence").
    static var id: String { get }

    /// Human-readable display name.
    static var displayName: String { get }

    /// Instance access to provider ID.
    var id: String { get }

    /// Translate a batch of requests, each optionally carrying surrounding subtitle lines as
    /// context. Providers that don't use context (e.g. Apple Intelligence) may ignore
    /// `contextBefore`/`contextAfter` and translate `text` directly.
    func translate(_ requests: [TranslationRequest]) async throws -> [String]

    /// Validates that required configuration is present (e.g. API keys in the environment,
    /// provider-specific options). Call before running a translation workflow.
    static func validateTranslationConfiguration(options: [String: String]) throws

    /// Rough pre-run cost estimate from subtitle payloads (token heuristic + published batch rates
    /// where available). Not a quote; actual usage may differ.
    func estimateCost(for requests: [TranslationRequest]) -> TranslationCostEstimate
}

extension TranslationProvider {
    public var id: String { Self.id }

    /// Default: no pre-flight checks. Override when API keys or options must be validated before translation.
    public static func validateTranslationConfiguration(options: [String: String]) throws {}
}

/// Registry of available translation providers. Use to resolve provider by ID.
public enum TranslationProviderRegistry {
    typealias Factory = @Sendable (Locale, Locale, [String: String]) throws -> any TranslationProvider

    private static let providers: [String: Factory] = [
        AppleIntelligenceTranslationProvider.id: { src, tgt, _ in
            try AppleIntelligenceTranslationProvider(sourceLocale: src, targetLocale: tgt)
        },
        OpenAIBatchTranslationProvider.id: { src, tgt, opts in
            try OpenAIBatchTranslationProvider(
                sourceLocale: src,
                targetLocale: tgt,
                model: opts["openai-model"],
                baseURL: opts["openai-base-url"].flatMap(URL.init(string:)),
                authMode: opts["openai-auth"]
            )
        },
    ]

    /// All registered provider IDs.
    public static var availableIDs: [String] { Array(providers.keys).sorted() }

    /// Throws if `id` is not a registered provider (e.g. invalid CLI `--translate-provider`).
    public static func validateProviderID(_ id: String) throws {
        guard providers[id] != nil else {
            throw TranslationError.unknownProvider(id, available: availableIDs)
        }
    }

    /// Validates provider-specific configuration (API keys, auth mode, Apple Intelligence availability, etc.).
    public static func validateProviderConfiguration(id: String, options: [String: String] = [:]) throws {
        try validateProviderID(id)
        switch id {
        case AppleIntelligenceTranslationProvider.id:
            try AppleIntelligenceTranslationProvider.validateTranslationConfiguration(options: options)
        case OpenAIBatchTranslationProvider.id:
            try OpenAIBatchTranslationProvider.validateTranslationConfiguration(options: options)
        default:
            break
        }
    }

    /// Resolve a provider by ID, or nil if unknown.
    public static func resolve(
        id: String, sourceLocale: Locale, targetLocale: Locale, options: [String: String] = [:]
    ) throws -> (any TranslationProvider)? {
        guard let factory = providers[id] else { return nil }
        return try factory(sourceLocale, targetLocale, options)
    }

    /// Resolve a provider by ID. Throws if the ID is unknown or the provider fails to initialize.
    public static func resolveOrThrow(
        id: String, sourceLocale: Locale, targetLocale: Locale, options: [String: String] = [:]
    ) throws -> any TranslationProvider {
        guard let provider = try resolve(id: id, sourceLocale: sourceLocale, targetLocale: targetLocale, options: options) else {
            throw TranslationError.unknownProvider(id, available: availableIDs)
        }
        return provider
    }
}

public enum TranslationError: LocalizedError {
    case unknownProvider(String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id, let available):
            return "Unknown translation provider: '\(id)'. Available: \(available.joined(separator: ", "))"
        }
    }
}
