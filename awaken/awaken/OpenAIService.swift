import Foundation
import os

struct OpenAIService {
    private let logger = Logger(subsystem: "com.phillipplanes.awaken", category: "openai")
    private let session: URLSession
    private let apiKey: String

    init(session: URLSession = .shared, apiKey: String) {
        self.session = session
        self.apiKey = apiKey
    }

    func generateScript(alarmType: AlarmType, alarmTime: Date, weatherSummary: String) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let alarmTimeText = formatter.string(from: alarmTime)

        let systemPrompt = """
        You write short alarm wake-up scripts.
        Keep it to 1-2 sentences, 12-28 words total.
        Be inspirational, practical, and positive.
        No hashtags, no emojis, no quotes, no lists.
        """

        let userPrompt = """
        Alarm type: \(alarmType.title)
        Alarm guidance: \(alarmType.instruction)
        Alarm time: \(alarmTimeText)
        Weather context: \(weatherSummary)

        Write one motivational wake-up message that lightly references the weather when useful.
        """

        let requestBody = ChatCompletionsRequest(
            model: "gpt-4o-mini",
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ],
            temperature: 0.8,
            maxCompletionTokens: 120
        )

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await performRequestWithRetry(request, operation: "chat.completions")
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw OpenAIServiceError.invalidResponse("No text returned from script generation.")
        }

        return content
    }

    func synthesizeSpeech(text: String, voice: String, format: String = "wav") async throws -> Data {
        let models = ["gpt-4o-mini-tts", "tts-1"]
        var lastError: Error?

        for model in models {
            do {
                let requestBody = SpeechRequest(model: model, input: text, voice: voice, format: format)

                var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder().encode(requestBody)

                let (data, response) = try await performRequestWithRetry(request, operation: "audio.speech.\(model)")
                try validate(response: response, data: data)
                return data
            } catch {
                lastError = error
            }
        }

        throw lastError ?? OpenAIServiceError.invalidResponse("Speech synthesis failed.")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse("Non-HTTP response from OpenAI.")
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            logger.error("OpenAI HTTP \(http.statusCode): \(body, privacy: .public)")
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw OpenAIServiceError.apiError(apiError.error.message)
            }
            throw OpenAIServiceError.apiError("OpenAI request failed with status \(http.statusCode).")
        }
    }

    private func performRequestWithRetry(
        _ request: URLRequest,
        operation: String,
        attempts: Int = 3
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                logger.info("OpenAI request \(operation, privacy: .public) attempt \(attempt)")
                return try await session.data(for: request)
            } catch {
                lastError = error
                let nsError = error as NSError
                logger.error(
                    "OpenAI request \(operation, privacy: .public) failed attempt \(attempt): domain=\(nsError.domain, privacy: .public) code=\(nsError.code) desc=\(nsError.localizedDescription, privacy: .public)"
                )
                if let urlError = error as? URLError, isRetryable(urlError), attempt < attempts {
                    try? await Task.sleep(for: .milliseconds(350 * attempt))
                    continue
                }
                if nsError.domain == "Foundation._GenericObjCError", attempt < attempts {
                    try? await Task.sleep(for: .milliseconds(350 * attempt))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? OpenAIServiceError.invalidResponse("OpenAI request failed.")
    }

    private func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

enum OpenAIServiceError: LocalizedError {
    case apiError(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let message):
            return message
        case .invalidResponse(let message):
            return message
        }
    }
}

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let maxCompletionTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxCompletionTokens = "max_completion_tokens"
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct SpeechRequest: Encodable {
    let model: String
    let input: String
    let voice: String
    let format: String

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case format = "response_format"
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
