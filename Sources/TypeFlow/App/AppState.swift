import Foundation

enum AppPhase: Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle
    private var recordingStartTime: Date?
    private var errorDismissTask: Task<Void, Never>?

    /// Transition: Idle → Recording. Returns false if not in Idle.
    func startRecording() -> Bool {
        guard phase == .idle else { return false }
        phase = .recording
        recordingStartTime = Date()
        return true
    }

    /// Transition: Recording → Processing (or back to Idle if too short).
    /// Returns recording duration, or nil if discarded.
    func stopRecording() -> TimeInterval? {
        guard phase == .recording else { return nil }
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil

        if duration < ConfigManager.shared.minRecordingDuration {
            phase = .idle
            print("[TypeFlow] Discarded: too short (\(String(format: "%.2f", duration))s)")
            return nil
        }

        phase = .processing
        return duration
    }

    /// Transition: Processing → Idle
    func finishProcessing() {
        guard phase == .processing else { return }
        phase = .idle
    }

    /// Transition: Any → Error (auto-dismiss after 2s)
    func showError(_ message: String) {
        phase = .error(message)
        errorDismissTask?.cancel()
        errorDismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if case .error = self.phase {
                self.phase = .idle
            }
        }
    }

    /// Check if recording exceeded max duration
    func shouldAutoStop() -> Bool {
        guard phase == .recording, let start = recordingStartTime else { return false }
        return Date().timeIntervalSince(start) >= ConfigManager.shared.maxRecordingDuration
    }

    /// Force reset to idle
    func reset() {
        errorDismissTask?.cancel()
        recordingStartTime = nil
        phase = .idle
    }
}
