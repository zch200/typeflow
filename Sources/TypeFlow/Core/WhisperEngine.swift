import Foundation
import CWhisper

enum WhisperError: Error, CustomStringConvertible {
    case modelNotFound(String)
    case loadFailed(String)
    case transcribeFailed
    case emptyResult

    var description: String {
        switch self {
        case .modelNotFound(let path): "Model not found: \(path)"
        case .loadFailed(let path): "Failed to load model: \(path)"
        case .transcribeFailed: "Transcription failed"
        case .emptyResult: "Transcription returned empty text"
        }
    }
}

actor WhisperEngine: SpeechEngine {
    private var context: OpaquePointer?
    private var idleTask: Task<Void, Never>?
    private let modelPath: String
    private let idleTimeout: TimeInterval = 300 // 5 minutes

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func transcribe(samples: [Float]) throws -> String {
        if context == nil {
            try loadModel()
        }
        resetIdleTimer()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.no_timestamps = true
        params.single_segment = false
        params.n_threads = max(1, Int32(ProcessInfo.processInfo.activeProcessorCount) - 2)

        let result: Int32 = "zh".withCString { lang in
            params.language = lang
            return samples.withUnsafeBufferPointer { buf in
                whisper_full(context, params, buf.baseAddress, Int32(buf.count))
            }
        }

        guard result == 0 else {
            throw WhisperError.transcribeFailed
        }

        let nSegments = whisper_full_n_segments(context)
        var text = ""
        for i in 0..<nSegments {
            if let seg = whisper_full_get_segment_text(context, i) {
                text += String(cString: seg)
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WhisperError.emptyResult
        }

        print("[TypeFlow] Transcribed: \(trimmed)")
        return trimmed
    }

    // MARK: - Model Lifecycle

    private func loadModel() throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelNotFound(modelPath)
        }

        print("[TypeFlow] Loading whisper model: \(modelPath)")
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperError.loadFailed(modelPath)
        }
        context = ctx
        print("[TypeFlow] Whisper model loaded")
    }

    private func unloadModel() {
        guard let ctx = context else { return }
        whisper_free(ctx)
        context = nil
        print("[TypeFlow] Whisper model unloaded (idle timeout)")
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(idleTimeout))
            guard !Task.isCancelled else { return }
            unloadModel()
        }
    }

    func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        unloadModel()
    }
}
