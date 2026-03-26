import Foundation

enum QwenCloudError: Error, CustomStringConvertible {
    case noApiKey
    case invalidEndpoint(String)
    case payloadTooLarge(Int)
    case httpError(Int, String)
    case unexpectedResponse
    case emptyResult

    var description: String {
        switch self {
        case .noApiKey: "Cloud ASR API key not configured"
        case .invalidEndpoint(let url): "Invalid endpoint URL: \(url)"
        case .payloadTooLarge(let bytes): "Audio too large for cloud ASR (\(bytes) bytes base64, limit 10 MB)"
        case .httpError(let code, let body): "HTTP \(code) — \(body.prefix(200))"
        case .unexpectedResponse: "Unexpected API response format"
        case .emptyResult: "Cloud ASR returned empty text"
        }
    }
}

actor QwenCloudEngine: SpeechEngine {
    private let endpoint: String
    private let model: String
    private let apiKey: String
    private let session: URLSession

    init(endpoint: String, model: String, apiKey: String) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard !apiKey.isEmpty else {
            throw QwenCloudError.noApiKey
        }

        let urlString = "\(endpoint)/v1/chat/completions"
        guard let url = URL(string: urlString) else {
            throw QwenCloudError.invalidEndpoint(urlString)
        }

        // PCM Float32 → WAV (PCM16) → base64
        let wavData = encodeWAV(samples: samples)
        let base64Audio = wavData.base64EncodedString()

        // 硬校验：base64 + data URI 前缀不超过 10 MB（十进制 10,000,000 bytes）
        let maxBase64Bytes = 9_800_000 // 留 200 KB 给 JSON 包装和其他字段
        if base64Audio.utf8.count > maxBase64Bytes {
            print("[TypeFlow] QwenCloud: payload too large — \(base64Audio.utf8.count) bytes base64")
            throw QwenCloudError.payloadTooLarge(base64Audio.utf8.count)
        }

        let audioDataURI = "data:audio/wav;base64,\(base64Audio)"

        print("[TypeFlow] QwenCloud: uploading \(wavData.count) bytes WAV (\(samples.count) samples, \(base64Audio.utf8.count) bytes base64)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": audioDataURI,
                                "format": "wav",
                            ],
                        ] as [String: Any],
                    ],
                ] as [String: Any],
            ],
            "asr_options": [
                "language": "zh",
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw QwenCloudError.unexpectedResponse
        }

        guard http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            print("[TypeFlow] QwenCloud: HTTP \(http.statusCode) — \(bodyStr.prefix(300))")
            throw QwenCloudError.httpError(http.statusCode, bodyStr)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            print("[TypeFlow] QwenCloud: unexpected response format")
            throw QwenCloudError.unexpectedResponse
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QwenCloudError.emptyResult
        }

        print("[TypeFlow] QwenCloud transcribed: \(trimmed)")
        return trimmed
    }

    func shutdown() {
        session.invalidateAndCancel()
    }

    // MARK: - WAV Encoding

    /// Encode PCM Float32 samples to WAV format (PCM16, 16kHz, mono).
    private func encodeWAV(samples: [Float]) -> Data {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2) // 2 bytes per Int16
        let fileSize = 36 + dataSize // total - 8 bytes for RIFF header

        var data = Data(capacity: Int(44 + dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.appendLittleEndian(fileSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.appendLittleEndian(UInt32(16))                 // chunk size
        data.appendLittleEndian(UInt16(1))                  // audio format: PCM
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.appendLittleEndian(dataSize)

        // PCM16 samples (Float32 → Int16, little-endian)
        for sample in samples {
            let clamped = Int16(clamping: Int32(sample * 32767))
            data.appendLittleEndian(clamped)
        }

        return data
    }
}

// MARK: - Data Little-Endian Helpers

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Int16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
