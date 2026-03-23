import Foundation

/// Shared user-message body for cloud batch translation (OpenAI chat + Gemini JSONL).
/// Kept in one place so cost estimates match what is actually sent.
enum TranslationMessageFormatting {
    static let maxCharsPerRequest = 4000

    static func userMessageText(for req: TranslationRequest) -> String {
        let text =
            req.text.count > maxCharsPerRequest
            ? String(req.text.prefix(maxCharsPerRequest))
            : req.text

        guard !req.contextBefore.isEmpty || !req.contextAfter.isEmpty else {
            return text
        }

        var parts: [String] = []
        if !req.contextBefore.isEmpty {
            parts.append("[Previous lines — context only, do not translate]")
            parts.append(req.contextBefore.joined(separator: "\n"))
            parts.append("")
        }
        parts.append("[Translate this line]")
        parts.append(text)
        if !req.contextAfter.isEmpty {
            parts.append("")
            parts.append("[Following lines — context only, do not translate]")
            parts.append(req.contextAfter.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }
}
