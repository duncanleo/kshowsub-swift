import Foundation

/// Translation provider using OpenAI's standard chat completions API.
///
/// **OpenAI-compatible gateways** (Gemini's OpenAI mode, Claude via proxies, OpenRouter, etc.):
/// Point `--openai-base-url` / `OPENAI_BASE_URL` at the gateway root (for example
/// `https://generativelanguage.googleapis.com/v1beta/openai`). The client appends
/// `/v1/chat/completions`.
///
/// Requires `OPENAI_API_KEY` env var. Model and base URL can be set via `--openai-model`
/// / `--openai-base-url` CLI options or `OPENAI_MODEL` / `OPENAI_BASE_URL` env vars
/// (CLI takes precedence).
struct OpenAIBatchTranslationProvider: TranslationProvider, Sendable {
    static let id = "openai-batch"
    static let displayName = "OpenAI"

    private static let defaultModel = "gpt-5.4-nano"
    private static let maxConcurrentRequests = 10
    private static let maxRequestsPerSecond = 1.5
    private static let maxItemsPerBatch = 200
    private static let maxCharsPerBatch = 200_000
    private static let maxBatchSplitDepth = 3
    private static let chatCompletionsPath = "/v1/chat/completions"
    private static let timeoutIntervalForRequest: TimeInterval = 180
    private static let timeoutIntervalForResource: TimeInterval = 600

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let promptPrefix: String
    private let singlePrompt: String
    private let authMode: APIAuthMode
    private let session: URLSession

    static func validateTranslationConfiguration(options: [String: String]) throws {
        guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false else {
            throw OpenAIBatchTranslationError.missingAPIKey
        }
        _ = try parseAuthMode(options["openai-auth"])
    }

    init(
        sourceLocale: Locale,
        targetLocale: Locale,
        model: String? = nil,
        baseURL: URL? = nil,
        authMode: String? = nil
    ) throws {
        var opts: [String: String] = [:]
        if let authMode { opts["openai-auth"] = authMode }
        try Self.validateTranslationConfiguration(options: opts)
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty
        else {
            throw OpenAIBatchTranslationError.missingAPIKey
        }

        self.apiKey = apiKey
        self.model =
            model
            ?? ProcessInfo.processInfo.environment["OPENAI_MODEL"]
            ?? Self.defaultModel
        self.baseURL =
            baseURL
            ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            ?? URL(string: "https://api.openai.com")!
        self.authMode = try Self.parseAuthMode(authMode)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = Self.timeoutIntervalForResource
        self.session = URLSession(configuration: configuration)

        let targetId =
            targetLocale.language.languageCode?.identifier
            ?? String(targetLocale.identifier.prefix(2))
        let targetName = targetId == "en" ? "English" : targetId
        let nounGuidanceLines: [String]
        if targetId == "en" {
            nounGuidanceLines = [
                "Do not use romanization, phonetic spelling, or pronunciation as the translation for common nouns, roles, titles, objects, generic places, food, slang labels, or descriptive nicknames. Translate their meaning into natural English instead.",
                "For transliterated descriptive compounds, infer the underlying meaning from context and translate the descriptor plus person/man/woman/lady/man as appropriate instead of preserving the source-language sound.",
                "For Korean-style descriptor suffixes such as romanized person, gender, age, or role markers, translate the whole descriptive label by meaning instead of preserving the suffix.",
                "Preserve personal names, brands, and established loanwords only when that is the natural English usage.",
            ]
        } else {
            nounGuidanceLines = [
                "Do not use romanization, phonetic spelling, or pronunciation as the translation for common nouns, roles, titles, objects, generic places, food, slang labels, or descriptive nicknames. Translate their meaning into natural target-language wording instead.",
                "Preserve personal names, brands, and established loanwords only when that is the natural target-language usage.",
            ]
        }
        let nounGuidance = nounGuidanceLines.joined(separator: "\n")
        promptPrefix =
            """
            Translate each numbered input line into \(targetName).
            Each input line is prefixed with a number and a period (e.g. "1. text").
            Return exactly one output line per input line, preserving the same number prefix (e.g. "1. translation").
            Translate the meaning of all content, including text inside parentheses, brackets, or braces.
            Some lines may be sentence fragments, partial phrases, slang, or appear incomplete — translate them as-is; never skip, merge, or discard any line.
            Use surrounding lines as context to produce natural, coherent translations, but still output one translated line per input line.
            A single input line may contain dialogue from multiple speakers or adjacent unrelated fragments. Translate each utterance in order and do not combine separate speakers, fragments, or sentences into one inferred sentence.
            Keep each translation at least as concise as its source line; prefer shorter subtitle wording over literal expansion.
            Preserve existing line breaks and parenthetical structure. If a source line is parenthesized, keep the translation parenthesized and do not merge it into dialogue.
            Avoid adding explanation, emphasis, filler, or extra words unless required for fluent target-language subtitles.
            Do not turn compact captions, labels, warnings, rules, or numbers into full explanatory sentences.
            \(nounGuidance)
            Never refuse, ask for clarification, or add commentary. If a line is ambiguous or unclear, provide your best translation anyway.
            Do not merge, split, or skip lines.
            Do not return XML, JSON, markdown, code fences, or commentary.
            """
        singlePrompt =
            """
            Translate the text into \(targetName).
            Use context only to disambiguate the text.
            The text may contain dialogue from multiple speakers or adjacent unrelated fragments. Translate each utterance in order and do not combine separate speakers, fragments, or sentences into one inferred sentence.
            Keep the translation at least as concise as the source text; prefer subtitle brevity over literal expansion.
            Preserve parenthetical structure and do not merge parenthetical text into dialogue.
            Do not turn compact captions, labels, warnings, rules, or numbers into full explanatory sentences.
            \(nounGuidance)
            Return only the translation.
            """
    }

    private enum APIAuthMode: Sendable {
        case bearer
        case apiKeyHeader(String)
    }

    private struct Usage: Sendable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var meteredResponses: Int = 0
    }

    private struct TranslationResponse: Sendable {
        let text: String
        let usage: Usage
    }

    private struct IndexedTranslation: Sendable {
        let index: Int
        let response: TranslationResponse
    }

    private struct BatchItem: Sendable {
        let index: Int
        let request: TranslationRequest
    }

    private struct BatchTranslationResult: Sendable {
        let translations: [IndexedTranslation]
        let usage: Usage
    }

    private struct ChatCompletionsRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double?
        let reasoning_effort: String?

        private enum CodingKeys: String, CodingKey {
            case model, messages, temperature, reasoning_effort
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encodeIfPresent(reasoning_effort, forKey: .reasoning_effort)
        }
    }

    private static func parseAuthMode(_ explicit: String?) throws -> APIAuthMode {
        let raw =
            (explicit ?? ProcessInfo.processInfo.environment["OPENAI_AUTH"] ?? "bearer")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "", "bearer":
            return .bearer
        case "x-api-key", "x_api_key", "api-key":
            return .apiKeyHeader("x-api-key")
        default:
            throw OpenAIBatchTranslationError.invalidAuthMode(raw)
        }
    }

    private func applyAuth(to request: inout URLRequest) {
        switch authMode {
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKeyHeader(let headerName):
            request.setValue(apiKey, forHTTPHeaderField: headerName)
        }
    }

    /// Standard-tier rates (USD per 1M tokens). Update from OpenAI pricing.
    /// https://platform.openai.com/docs/pricing
    private static func pricingUSDPerMillionTokens(for model: String) -> (
        input: Double, output: Double
    ) {
        let m = model.lowercased()
        if m.contains("gpt-5.4-nano") { return (0.20, 1.25) }
        if m.contains("gpt-4o-mini") { return (0.15, 0.60) }
        if m.contains("gpt-4o") { return (2.50, 10.00) }
        if m.contains("gpt-5-nano") { return (0.05, 0.40) }
        return (0.05, 0.40)
    }

    func estimateCost(for requests: [TranslationRequest]) -> TranslationCostEstimate {
        guard !requests.isEmpty else {
            return TranslationCostEstimate(
                estimatedUSD: 0,
                lines: ["Estimated API cost: $0 (nothing to translate)."]
            )
        }
        return TranslationCostEstimate(
            estimatedUSD: nil,
            lines: [
                "Actual API cost will be reported after completion from OpenAI usage totals for \(requests.count) request(s).",
                "Pricing uses non-batch OpenAI rates; your project or gateway may bill differently.",
            ]
        )
    }

    func translate(_ requests: [TranslationRequest]) async throws -> [String] {
        guard !requests.isEmpty else { return [] }

        var results = Array(repeating: "", count: requests.count)
        var totalUsage = Usage()
        let batches = makeBatches(from: requests)
        var nextBatchIndex = 0
        let provider = self
        let pacer = RequestPacer(requestsPerSecond: Self.maxRequestsPerSecond)
        let progress = TranslationProgressReporter(
            label: "OpenAI",
            total: requests.count,
            unitLabel: "lines",
            inFlightLabel: "requests in flight"
        )

        await progress.start()

        try await withThrowingTaskGroup(of: BatchTranslationResult.self) { group in
            let initialCount = min(Self.maxConcurrentRequests, batches.count)
            for _ in 0..<initialCount {
                let batchIndex = nextBatchIndex
                nextBatchIndex += 1
                let batch = batches[batchIndex]
                await progress.markStarted()
                group.addTask {
                    try await pacer.acquire()
                    return try await provider.translateBatchWithRetry(
                        batch,
                        totalRequests: requests.count,
                        splitDepth: 0
                    )
                }
            }

            while let batchResult = try await group.next() {
                for item in batchResult.translations {
                    results[item.index] = item.response.text
                }
                totalUsage.inputTokens += batchResult.usage.inputTokens
                totalUsage.outputTokens += batchResult.usage.outputTokens
                totalUsage.meteredResponses += batchResult.usage.meteredResponses
                await progress.markCompleted(count: batchResult.translations.count)

                if nextBatchIndex < batches.count {
                    let batchIndex = nextBatchIndex
                    nextBatchIndex += 1
                    let batch = batches[batchIndex]
                    await progress.markStarted()
                    group.addTask {
                        try await pacer.acquire()
                        return try await provider.translateBatchWithRetry(
                            batch,
                            totalRequests: requests.count,
                            splitDepth: 0
                        )
                    }
                }
            }
        }

        await progress.finish()
        emitActualCostSummary(usage: totalUsage, totalRequests: requests.count)
        return results
    }

    private func translateBatchWithRetry(
        _ batch: [BatchItem],
        totalRequests: Int,
        splitDepth: Int
    ) async throws -> BatchTranslationResult {
        do {
            return try await translateBatch(batch, totalRequests: totalRequests)
        } catch let error as OpenAIBatchTranslationError {
            if batch.count == 1 {
                let translated = try await translateSingleItem(
                    batch[0], totalRequests: totalRequests)
                return BatchTranslationResult(
                    translations: [translated],
                    usage: translated.response.usage
                )
            }

            let shouldSplit: Bool
            switch error {
            case .missingOutput, .invalidBatchResponse:
                shouldSplit = true
            default:
                shouldSplit = false
            }
            guard shouldSplit, batch.count > 1, splitDepth < Self.maxBatchSplitDepth else {
                throw error
            }

            let midpoint = batch.count / 2
            let firstHalf = Array(batch[..<midpoint])
            let secondHalf = Array(batch[midpoint...])
            fputs(
                "OpenAI: retrying incomplete batch by splitting \(batch.count) items into \(firstHalf.count)+\(secondHalf.count).\n",
                stderr
            )

            async let left = translateBatchWithRetry(
                firstHalf,
                totalRequests: totalRequests,
                splitDepth: splitDepth + 1
            )
            async let right = translateBatchWithRetry(
                secondHalf,
                totalRequests: totalRequests,
                splitDepth: splitDepth + 1
            )
            let (leftResult, rightResult) = try await (left, right)
            return BatchTranslationResult(
                translations: leftResult.translations + rightResult.translations,
                usage: Usage(
                    inputTokens: leftResult.usage.inputTokens + rightResult.usage.inputTokens,
                    outputTokens: leftResult.usage.outputTokens + rightResult.usage.outputTokens,
                    meteredResponses: leftResult.usage.meteredResponses
                        + rightResult.usage.meteredResponses
                )
            )
        }
    }

    private func translateBatch(
        _ batch: [BatchItem],
        totalRequests: Int
    ) async throws -> BatchTranslationResult {
        let userMessage = sanitizedJSONText(userMessageText(for: batch))
        let payload = ChatCompletionsRequest(
            model: model,
            messages: [
                .init(role: "system", content: sanitizedJSONText(promptPrefix)),
                .init(role: "user", content: userMessage),
            ],
            temperature: modelSpecificTemperature(),
            reasoning_effort: modelSpecificReasoningEffort()
        )

        var urlRequest = URLRequest(url: apiURL(path: Self.chatCompletionsPath))
        urlRequest.httpMethod = "POST"
        applyAuth(to: &urlRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try JSONEncoder().encode(payload)
        urlRequest.httpBody = requestBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
            try validateHTTP(response: response, data: data)
        } catch {
            logRequestError(error, requestBody: requestBody, responseBody: nil)
            throw error
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let text = textFromChoiceMessage(message)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            let missingErr = OpenAIBatchTranslationError.missingOutput(
                customId: String(batch.first?.index ?? -1),
                total: totalRequests
            )
            logRequestError(missingErr, requestBody: requestBody, responseBody: data)
            throw missingErr
        }

        let translatedLines: [String]
        do {
            translatedLines = try parseLineBatchResponse(text, expectedCount: batch.count)
        } catch let error as OpenAIBatchTranslationError {
            switch error {
            case .invalidBatchResponse(let detail, _):
                let wrapped = OpenAIBatchTranslationError.invalidBatchResponse(
                    detail: detail, rawOutput: text)
                logLineMismatch(error: wrapped, inputBatch: batch, responseText: text)
                throw wrapped
            default:
                logRequestError(error, requestBody: requestBody, responseBody: data)
                throw error
            }
        }
        let usage = Self.extractUsage(from: json) ?? Usage()
        let translations = zip(batch, translatedLines).map { item, translated in
            return IndexedTranslation(
                index: item.index,
                response: TranslationResponse(text: translated, usage: Usage())
            )
        }
        return BatchTranslationResult(translations: translations, usage: usage)
    }

    private func translateSingleItem(
        _ item: BatchItem,
        totalRequests: Int
    ) async throws -> IndexedTranslation {
        let req = item.request
        let text =
            req.text.count > TranslationMessageFormatting.maxCharsPerRequest
            ? String(req.text.prefix(TranslationMessageFormatting.maxCharsPerRequest))
            : req.text

        var bodyParts: [String] = []
        if !req.contextBefore.isEmpty {
            bodyParts.append("Context before:")
            bodyParts.append(req.contextBefore.joined(separator: "\n"))
        }
        bodyParts.append("Text:")
        bodyParts.append(text)
        if !req.contextAfter.isEmpty {
            bodyParts.append("Context after:")
            bodyParts.append(req.contextAfter.joined(separator: "\n"))
        }

        let userMessage = sanitizedJSONText(bodyParts.joined(separator: "\n\n"))
        let payload = ChatCompletionsRequest(
            model: model,
            messages: [
                .init(role: "system", content: sanitizedJSONText(singlePrompt)),
                .init(role: "user", content: userMessage),
            ],
            temperature: modelSpecificTemperature(),
            reasoning_effort: modelSpecificReasoningEffort()
        )

        var urlRequest = URLRequest(url: apiURL(path: Self.chatCompletionsPath))
        urlRequest.httpMethod = "POST"
        applyAuth(to: &urlRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try JSONEncoder().encode(payload)
        urlRequest.httpBody = requestBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
            try validateHTTP(response: response, data: data)
        } catch {
            logRequestError(error, requestBody: requestBody, responseBody: nil)
            throw error
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let text = textFromChoiceMessage(message)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            let missingErr = OpenAIBatchTranslationError.missingOutput(
                customId: String(item.index),
                total: totalRequests
            )
            logRequestError(missingErr, requestBody: requestBody, responseBody: data)
            throw missingErr
        }

        return IndexedTranslation(
            index: item.index,
            response: TranslationResponse(
                text: text,
                usage: Self.extractUsage(from: json) ?? Usage()
            )
        )
    }

    private func modelSpecificReasoningEffort() -> String? {
        let normalizedModel = model.lowercased()
        if Self.isGPT5Dot4ClassModel(normalizedModel) {
            return "none"
        }
        if Self.isGPT5ClassModel(normalizedModel) {
            return "low"
        }
        return nil
    }

    private func userMessageText(for batch: [BatchItem]) -> String {
        batch.enumerated().map { offset, item in
            "\(offset + 1). \(normalizedBatchLine(from: item.request))"
        }
        .joined(separator: "\n")
    }

    private func sanitizedJSONText(_ string: String) -> String {
        String(
            string.unicodeScalars.filter { scalar in
                switch scalar.value {
                case 0x09, 0x0A, 0x0D:
                    return true
                case 0x00...0x1F:
                    return false
                default:
                    return true
                }
            }
        )
    }

    private func modelSpecificTemperature() -> Double? {
        let normalizedModel = model.lowercased()
        if Self.isGPT5ClassModel(normalizedModel) {
            return nil
        }
        return 0.3
    }

    private static func isGPT5Dot4ClassModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-5.4")
    }

    private static func isGPT5ClassModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-5")
    }

    private static func isGPT4ClassModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-4")
    }

    /// Strips a leading "N. " or "N) " number prefix that the model echoes back.
    private func stripNumberPrefix(from line: String) -> String {
        var idx = line.startIndex
        while idx < line.endIndex && line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex, idx < line.endIndex,
            line[idx] == "." || line[idx] == ")"
        else { return line }
        let afterDelimiter = line.index(after: idx)
        guard afterDelimiter < line.endIndex, line[afterDelimiter] == " " else { return line }
        return String(line[line.index(after: afterDelimiter)...])
    }

    private func normalizedBatchLine(from request: TranslationRequest) -> String {
        let text =
            request.text.count > TranslationMessageFormatting.maxCharsPerRequest
            ? String(request.text.prefix(TranslationMessageFormatting.maxCharsPerRequest))
            : request.text
        return
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: " / ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseLineBatchResponse(_ text: String, expectedCount: Int) throws -> [String] {
        let normalized =
            text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lines =
            normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let stripped = stripCodeFences(from: lines) {
            lines = stripped
        }

        lines = lines.map { stripNumberPrefix(from: $0) }

        if lines.count > expectedCount {
            lines = trimCommentaryLines(from: lines, expectedCount: expectedCount)
        }

        if lines.count > expectedCount {
            lines = Array(lines.suffix(expectedCount))
        }

        guard lines.count == expectedCount else {
            throw OpenAIBatchTranslationError.invalidBatchResponse(
                detail: "Expected \(expectedCount) translated lines, got \(lines.count).",
                rawOutput: text
            )
        }

        return lines
    }

    private func stripCodeFences(from lines: [String]) -> [String]? {
        guard
            lines.count >= 3,
            lines.first?.hasPrefix("```") == true,
            lines.last?.hasPrefix("```") == true
        else {
            return nil
        }
        return Array(lines.dropFirst().dropLast())
    }

    private func trimCommentaryLines(from lines: [String], expectedCount: Int) -> [String] {
        var trimmed = lines

        while trimmed.count > expectedCount, let first = trimmed.first, isLikelyCommentary(first) {
            trimmed.removeFirst()
        }

        while trimmed.count > expectedCount, let last = trimmed.last, isLikelyCommentary(last) {
            trimmed.removeLast()
        }

        return trimmed
    }

    private func isLikelyCommentary(_ line: String) -> Bool {
        let lower = line.lowercased()
        return
            lower.hasPrefix("here")
            || lower.hasPrefix("sure")
            || lower.hasPrefix("translation")
            || lower.hasPrefix("translations")
            || lower.hasPrefix("output")
            || lower.hasPrefix("note:")
            || lower.hasPrefix("```")
    }

    private func makeBatches(from requests: [TranslationRequest]) -> [[BatchItem]] {
        var batches: [[BatchItem]] = []
        var currentBatch: [BatchItem] = []
        var currentChars = 0

        for (index, request) in requests.enumerated() {
            let estimatedChars =
                min(request.text.count, TranslationMessageFormatting.maxCharsPerRequest)
                + request.contextBefore.joined(separator: "\n").count
                + request.contextAfter.joined(separator: "\n").count
                + 128

            let shouldFlush =
                !currentBatch.isEmpty
                && (currentBatch.count >= Self.maxItemsPerBatch
                    || currentChars + estimatedChars > Self.maxCharsPerBatch)
            if shouldFlush {
                batches.append(currentBatch)
                currentBatch = []
                currentChars = 0
            }

            currentBatch.append(BatchItem(index: index, request: request))
            currentChars += estimatedChars
        }

        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        return batches
    }

    private func apiURL(path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + suffix) else {
            preconditionFailure("invalid API base URL")
        }
        return url
    }

    private static func errorDetail(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any] {
                if let m = err["message"] as? String { return m }
                if let m = err["detail"] as? String { return m }
            }
            if let m = obj["message"] as? String { return m }
            if let m = obj["detail"] as? String { return m }
        }
        return String(data: data, encoding: .utf8) ?? "(no body)"
    }

    private func logLineMismatch(error: Error, inputBatch: [BatchItem], responseText: String) {
        fputs("OpenAI: error — \(error.localizedDescription)\n", stderr)
        let inputLines = inputBatch.map { normalizedBatchLine(from: $0.request) }
        let outputLines =
            responseText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        fputs("--- Input lines (\(inputLines.count)) ---\n", stderr)
        for (i, line) in inputLines.enumerated() {
            fputs("  \(i + 1): \(line)\n", stderr)
        }
        fputs("--- Output lines (\(outputLines.count)) ---\n", stderr)
        for (i, line) in outputLines.enumerated() {
            fputs("  \(i + 1): \(line)\n", stderr)
        }
        fputs("----------------------------------------\n", stderr)
    }

    private func logRequestError(_ error: Error, requestBody: Data?, responseBody: Data?) {
        fputs("OpenAI: error — \(error.localizedDescription)\n", stderr)
        if let body = requestBody, let text = String(data: body, encoding: .utf8) {
            fputs("--- Request body ---\n\(text)\n--------------------\n", stderr)
        }
        if let body = responseBody, let text = String(data: body, encoding: .utf8) {
            fputs("--- Response body ---\n\(text)\n---------------------\n", stderr)
        }
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIBatchTranslationError.requestFailed(
                statusCode: -1,
                detail: "Not an HTTP response"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIBatchTranslationError.requestFailed(
                statusCode: http.statusCode,
                detail: Self.errorDetail(from: data)
            )
        }
    }

    /// Some OpenAI-compatible APIs return `content` as a string; others use an array of
    /// `{type,text}` parts.
    private func textFromChoiceMessage(_ message: [String: Any]) -> String? {
        if let s = message["content"] as? String {
            return s
        }
        if let parts = message["content"] as? [[String: Any]] {
            var chunks: [String] = []
            for part in parts {
                if let t = part["text"] as? String {
                    chunks.append(t)
                } else if let t = part["content"] as? String {
                    chunks.append(t)
                }
            }
            if !chunks.isEmpty {
                return chunks.joined()
            }
        }
        return nil
    }

    private static func extractUsage(from body: [String: Any]) -> Usage? {
        guard let usage = body["usage"] as? [String: Any] else { return nil }
        let inputTokens =
            intValue(usage["prompt_tokens"])
            ?? intValue(usage["input_tokens"])
            ?? 0
        let outputTokens =
            intValue(usage["completion_tokens"])
            ?? intValue(usage["output_tokens"])
            ?? 0
        return Usage(inputTokens: inputTokens, outputTokens: outputTokens, meteredResponses: 1)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func emitActualCostSummary(usage: Usage, totalRequests: Int) {
        guard usage.meteredResponses > 0 else {
            fputs(
                "Actual API cost could not be computed: responses did not include usage totals.\n",
                stderr
            )
            return
        }

        let rates = Self.pricingUSDPerMillionTokens(for: model)
        let inputCost = Double(usage.inputTokens) / 1_000_000.0 * rates.input
        let outputCost = Double(usage.outputTokens) / 1_000_000.0 * rates.output
        let total = inputCost + outputCost
        let summary = String(
            format:
                "Actual API cost (OpenAI, model %@): $%.4f USD (%d/%d responses reported usage; %d input + %d output tokens).",
            model,
            total,
            usage.meteredResponses,
            totalRequests,
            usage.inputTokens,
            usage.outputTokens
        )
        fputs("\(summary)\n", stderr)
    }
}

enum OpenAIBatchTranslationError: LocalizedError {
    case missingAPIKey
    case encodingFailed
    case invalidAuthMode(String)
    case requestFailed(statusCode: Int, detail: String)
    case batchFailed(status: String, errorFileID: String)
    case invalidBatchResponse(detail: String, rawOutput: String?)
    case missingOutput(customId: String, total: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return
                "OPENAI_API_KEY is not set. Set it in the environment to use the OpenAI provider."
        case .encodingFailed:
            return "Failed to encode OpenAI request payload."
        case .invalidAuthMode(let mode):
            return
                "Invalid openai auth mode '\(mode)'. Use 'bearer' or 'x-api-key' (or set OPENAI_AUTH)."
        case .requestFailed(let statusCode, let detail):
            return "OpenAI API request failed (HTTP \(statusCode)): \(detail)"
        case .batchFailed(let status, let errorFileID):
            return "OpenAI request failed (\(status)). \(errorFileID)"
        case .invalidBatchResponse(let detail, _):
            return "OpenAI batch response could not be parsed: \(detail)"
        case .missingOutput(let customId, let total):
            return
                "OpenAI response missing translation for request \(customId) (\(total) total)."
        }
    }
}
