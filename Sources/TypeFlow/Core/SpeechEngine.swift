import Foundation

enum SpeechEngineType: Int, Sendable, CaseIterable {
    case whisperLocal = 0
    case qwenCloud = 1
}

protocol SpeechEngine: Sendable {
    func transcribe(samples: [Float]) async throws -> String
    func shutdown() async
}
