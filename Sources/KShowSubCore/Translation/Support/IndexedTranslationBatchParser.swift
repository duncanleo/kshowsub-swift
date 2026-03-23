import Foundation

enum IndexedTranslationBatchParser {
    static func parse(xml: String) throws -> [Int: String] {
        let normalized = normalizeResponse(xml)
        if let parsedFromItems = try parseItemElements(in: normalized), !parsedFromItems.isEmpty {
            return parsedFromItems
        }
        if let parsedFromLines = try parseIndexedLines(in: normalized), !parsedFromLines.isEmpty {
            return parsedFromLines
        }
        throw IndexedTranslationBatchParserError.invalidXML(
            "No indexed translation items found in model output"
        )
    }

    private static func parseItemElements(in string: String) throws -> [Int: String]? {
        let pattern = #"<item\s+index="(\d+)">([\s\S]*?)</item>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsRange = NSRange(string.startIndex..<string.endIndex, in: string)
        let matches = regex.matches(in: string, options: [], range: nsRange)
        guard !matches.isEmpty else { return nil }

        var translations: [Int: String] = [:]
        for match in matches {
            guard
                match.numberOfRanges == 3,
                let indexRange = Range(match.range(at: 1), in: string),
                let textRange = Range(match.range(at: 2), in: string),
                let index = Int(string[indexRange])
            else {
                continue
            }

            let rawText = String(string[textRange])
            translations[index] = decodeXMLText(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return translations.isEmpty ? nil : translations
    }

    private static func parseIndexedLines(in string: String) throws -> [Int: String]? {
        let pattern = #"(?m)^\s*(\d+)\s*[:\-]\s*(.+)$"#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let nsRange = NSRange(string.startIndex..<string.endIndex, in: string)
        let matches = regex.matches(in: string, options: [], range: nsRange)
        guard !matches.isEmpty else { return nil }

        var translations: [Int: String] = [:]
        for match in matches {
            guard
                match.numberOfRanges == 3,
                let indexRange = Range(match.range(at: 1), in: string),
                let textRange = Range(match.range(at: 2), in: string),
                let index = Int(string[indexRange])
            else {
                continue
            }
            translations[index] = String(string[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return translations.isEmpty ? nil : translations
    }

    private static func normalizeResponse(_ string: String) -> String {
        var result = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            let lines = result.components(separatedBy: .newlines)
            let stripped = lines.dropFirst().dropLast().joined(separator: "\n")
            if !stripped.isEmpty {
                result = stripped
            }
        }
        return result
    }

    private static func decodeXMLText(_ string: String) -> String {
        var result = string
        if result.hasPrefix("<![CDATA["), result.hasSuffix("]]>") {
            result.removeFirst("<![CDATA[".count)
            result.removeLast("]]>".count)
            return result
        }

        return result
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum IndexedTranslationBatchParserError: LocalizedError {
    case invalidXML(String)

    var errorDescription: String? {
        switch self {
        case .invalidXML(let detail):
            return "Failed to parse translation batch XML: \(detail)"
        }
    }
}
