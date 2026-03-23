import Foundation
import FoundationModels

/// Translation provider using Apple Intelligence (Foundation Models).
/// Requires Apple Intelligence enabled and permissiveContentTransformations for subtitle content.
struct AppleIntelligenceTranslationProvider: TranslationProvider, Sendable {
    static let id = "apple-intelligence"
    static let displayName = "Apple Intelligence"

    /// Per-chunk char limit. Context window is 4096 for input+output; overhead ≈4000, must leave room for response.
    private static let maxCharsPerChunk = 30

    /// Max concurrent chunk translations (bounded to avoid overwhelming the on-device model).
    private static let maxConcurrentChunks = 4

    private let promptPrefix: String
    private let model: SystemLanguageModel

    static func validateTranslationConfiguration(options: [String: String]) throws {
        _ = options
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        try Self.requireAvailability(of: model)
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

    init(sourceLocale: Locale, targetLocale: Locale) throws {
        let targetId =
            targetLocale.language.languageCode?.identifier
            ?? String(targetLocale.identifier.prefix(2))
        let targetName = targetId == "en" ? "English" : targetId
        promptPrefix =
            "Translate to \(targetName). Output only the translation. No preamble or questions.\n"

        let created = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        try Self.requireAvailability(of: created)
        model = created
    }

    func estimateCost(for requests: [TranslationRequest]) -> TranslationCostEstimate {
        guard !requests.isEmpty else {
            return TranslationCostEstimate(
                estimatedUSD: 0,
                lines: ["Estimated API cost: $0 (nothing to translate)."]
            )
        }
        var invocations = 0
        for req in requests {
            invocations += Self.chunk(req.text, maxChars: Self.maxCharsPerChunk).count
        }
        return TranslationCostEstimate(
            estimatedUSD: 0,
            lines: [
                "Estimated API cost: $0 (on-device Apple Intelligence).",
                "About \(invocations) model invocations across \(requests.count) unique strings (max \(Self.maxCharsPerChunk) chars per chunk).",
            ]
        )
    }

    func translate(_ requests: [TranslationRequest]) async throws -> [String] {
        let maxConcurrent = Self.maxConcurrentChunks
        var results: [String] = Array(repeating: "", count: requests.count)
        for batchStart in stride(from: 0, to: requests.count, by: maxConcurrent) {
            let batchEnd = min(batchStart + maxConcurrent, requests.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in batchStart..<batchEnd {
                    let text = requests[i].text
                    group.addTask { [self] in
                        let r = try await translateSingle(text)
                        return (i, r)
                    }
                }
                for try await (idx, translated) in group {
                    results[idx] = translated
                }
            }
        }
        return results
    }

    private func translateSingle(_ string: String) async throws -> String {
        let chunks = Self.chunk(string, maxChars: Self.maxCharsPerChunk)
        var results: [String] = Array(repeating: "", count: chunks.count)

        for batchStart in stride(from: 0, to: chunks.count, by: Self.maxConcurrentChunks) {
            let batchEnd = min(batchStart + Self.maxConcurrentChunks, chunks.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in batchStart..<batchEnd {
                    let chunk = chunks[i]
                    group.addTask { [self] in
                        let session = LanguageModelSession(model: model, instructions: nil)
                        let prompt = promptPrefix + chunk
                        let response = try await session.respond(to: prompt)
                        let translated = try response.rawContent.value(String.self)
                        return (i, translated.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                for try await (idx, translated) in group {
                    results[idx] = translated
                }
            }
        }
        return results.joined(separator: "\n")
    }

    /// Splits text into chunks of maxChars, preferring line boundaries.
    private static func chunk(_ text: String, maxChars: Int) -> [String] {
        let lines = text.replacingOccurrences(of: "\\N", with: "\n").components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""
        for line in lines {
            let next = current.isEmpty ? line : current + "\n" + line
            if next.count <= maxChars {
                current = next
            } else {
                if !current.isEmpty {
                    chunks.append(current)
                }
                if line.count <= maxChars {
                    current = line
                } else {
                    var remain = line
                    while !remain.isEmpty {
                        let end =
                            remain.index(
                                remain.startIndex, offsetBy: min(maxChars, remain.count),
                                limitedBy: remain.endIndex) ?? remain.endIndex
                        chunks.append(String(remain[..<end]))
                        remain = end < remain.endIndex ? String(remain[end...]) : ""
                    }
                    current = ""
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

enum AppleIntelligenceError: LocalizedError {
    case deviceNotEligible
    case notEnabled
    case modelNotReady
    case other(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .notEnabled:
            return
                "Apple Intelligence is not enabled. Enable in System Settings → Apple Intelligence & Siri."
        case .modelNotReady:
            return "Apple Intelligence model is not ready (may be downloading). Try again later."
        case .other(let msg):
            return "Apple Intelligence unavailable: \(msg)"
        }
    }
}
