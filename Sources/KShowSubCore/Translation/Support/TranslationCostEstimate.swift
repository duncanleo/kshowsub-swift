import Foundation

/// Rough token count for API billing. Uses a UTF-8 byte length heuristic (~4 bytes per token),
/// which is in the ballpark for Latin and CJK subtitle text; real tokenizers differ.
func approximateTokenCount(_ text: String) -> Int {
    let n = text.utf8.count
    guard n > 0 else { return 0 }
    return (n + 3) / 4
}

/// Pre-run cost hint for a translation provider. Dollar amounts are **approximate**; check the
/// vendor's pricing page for authoritative billing.
public struct TranslationCostEstimate: Sendable {
    /// Best-effort total in USD when applicable.
    public let estimatedUSD: Double?
    /// One or more lines suitable for stderr (caller may prefix or wrap).
    public let lines: [String]

    public init(estimatedUSD: Double?, lines: [String]) {
        self.estimatedUSD = estimatedUSD
        self.lines = lines
    }
}
