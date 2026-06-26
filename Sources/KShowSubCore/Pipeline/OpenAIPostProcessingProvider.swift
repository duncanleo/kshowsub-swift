import Foundation

struct OpenAIPostProcessingProvider: SubtitlePostProcessingProvider, Sendable {
    static let id = "openai"
    static let displayName = "OpenAI-compatible"
    let maxPromptCharacters: Int? = 6_000

    private static let defaultModel = "gpt-5.4-nano"
    private static let chatCompletionsPath = "/v1/chat/completions"
    private static let timeoutIntervalForRequest: TimeInterval = 180
    private static let timeoutIntervalForResource: TimeInterval = 600

    private let apiKey: String
    private let baseURL: URL
    private let model: String
    private let authMode: APIAuthMode
    private let locale: Locale
    private let session: URLSession

    static func validatePostProcessingConfiguration(options: [String: String]) throws {
        guard ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false else {
            throw OpenAIBatchTranslationError.missingAPIKey
        }
        _ = try parseAuthMode(options["openai-auth"])
    }

    init(
        locale: Locale,
        model: String? = nil,
        baseURL: URL? = nil,
        authMode: String? = nil
    ) throws {
        var opts: [String: String] = [:]
        if let authMode { opts["openai-auth"] = authMode }
        try Self.validatePostProcessingConfiguration(options: opts)
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
        self.locale = locale
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = Self.timeoutIntervalForResource
        self.session = URLSession(configuration: configuration)
    }

    private enum APIAuthMode: Sendable {
        case bearer
        case apiKeyHeader(String)
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
    }

    func estimateCost(for batch: PostProcessingInputBatch) -> TranslationCostEstimate {
        TranslationCostEstimate(
            estimatedUSD: nil,
            lines: [
                "Post-processing will send \(batch.cues.count) input cue(s) to the configured OpenAI-compatible provider; billing depends on that provider."
            ]
        )
    }

    func postProcess(_ batch: PostProcessingInputBatch) async throws -> [PostProcessedCue] {
        guard !batch.cues.isEmpty else { return [] }
        let payload = ChatCompletionsRequest(
            model: model,
            messages: [
                .init(
                    role: "system",
                    content: sanitizedJSONText(
                        PostProcessingPrompt.systemPrompt(locale: locale, profile: .openAI)
                    )
                ),
                .init(role: "user", content: sanitizedJSONText(PostProcessingPrompt.userPrompt(batch: batch))),
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
            let error = PostProcessingError.invalidResponse("Missing assistant message content.")
            logRequestError(error, requestBody: requestBody, responseBody: data)
            throw error
        }

        return try PostProcessingResponseParser.parse(text)
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

    private func modelSpecificReasoningEffort() -> String? {
        let normalizedModel = model.lowercased()
        if normalizedModel.hasPrefix("gpt-5.4") {
            return "medium"
        }
        if normalizedModel.hasPrefix("gpt-5") {
            return "medium"
        }
        return nil
    }

    private func modelSpecificTemperature() -> Double? {
        if model.lowercased().hasPrefix("gpt-5") {
            return nil
        }
        return 0.2
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

    private func apiURL(path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        guard let url = URL(string: base + suffix) else {
            preconditionFailure("invalid API base URL")
        }
        return url
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

    private func logRequestError(_ error: Error, requestBody: Data?, responseBody: Data?) {
        fputs("OpenAI post-process: error — \(error.localizedDescription)\n", stderr)
        if let body = requestBody, let text = String(data: body, encoding: .utf8) {
            fputs("--- Request body ---\n\(text)\n--------------------\n", stderr)
        }
        if let body = responseBody, let text = String(data: body, encoding: .utf8) {
            fputs("--- Response body ---\n\(text)\n---------------------\n", stderr)
        }
    }
}
