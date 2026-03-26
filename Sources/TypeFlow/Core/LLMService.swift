import Foundation

@MainActor
final class LLMService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    /// Polish transcribed text via LLM. Always returns a string — degrades to raw text on any failure.
    func polish(text: String) async -> String {
        let config = ConfigManager.shared

        guard let apiKey = config.llmApiKey, !apiKey.isEmpty else {
            print("[TypeFlow] LLM: no API key — skipping polish")
            return text
        }

        guard let url = URL(string: "\(config.llmEndpoint)/v1/chat/completions") else {
            print("[TypeFlow] LLM: invalid endpoint URL")
            return text
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": config.llmModel,
            "messages": [
                ["role": "system", "content": config.llmSystemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.2,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                print("[TypeFlow] LLM: HTTP \(code) — \(bodyStr.prefix(200))")
                return text
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  !content.isEmpty else {
                print("[TypeFlow] LLM: unexpected response format")
                return text
            }

            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[TypeFlow] LLM: \(error.localizedDescription)")
            return text
        }
    }
}
