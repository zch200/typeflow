import AppKit
import ApplicationServices
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusBar: StatusBarController?
    private var hotkeyManager: HotkeyManager?
    private let audioRecorder = AudioRecorder()
    private var whisperEngine: WhisperEngine?
    private let llmService = LLMService()
    private let textOutputManager = TextOutputManager()
    private var floatingIndicator: FloatingIndicator?
    private var maxDurationTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var indicatorHideTask: Task<Void, Never>?
    private var micPermissionGranted = false

    private static let defaultModelName = "ggml-large-v3-turbo.bin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let axTrusted = AXIsProcessTrusted()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[TypeFlow] Launch: AXIsProcessTrusted=\(axTrusted), microphoneStatus=\(micStatus.label)")

        statusBar = StatusBarController(appState: appState)
        statusBar?.onRetryPermission = { [weak self] in self?.retryPermissionCheck() }
        floatingIndicator = FloatingIndicator()

        // Cache mic permission if already granted
        if micStatus == .authorized {
            micPermissionGranted = true
        } else if micStatus == .denied || micStatus == .restricted {
            statusBar?.showMicPermissionHint(true)
        }

        // Initialize whisper engine
        let modelDir = ConfigManager.shared.modelDirectory
        let modelPath = (modelDir as NSString).appendingPathComponent(Self.defaultModelName)
        whisperEngine = WhisperEngine(modelPath: modelPath)
        if !FileManager.default.fileExists(atPath: modelPath) {
            print("[TypeFlow] Warning: model not found at \(modelPath)")
            print("[TypeFlow] Download a whisper model and place it there to enable transcription")
        }

        if axTrusted {
            if !setupHotkey() {
                startPermissionPolling()
            }
        } else {
            print("[TypeFlow] Accessibility permission not granted — hotkey disabled")
            statusBar?.updateHotkeyStatus(enabled: false)
            statusBar?.showPermissionHint(true)
            startPermissionPolling()
        }
    }

    // MARK: - Hotkey Setup

    @discardableResult
    private func setupHotkey() -> Bool {
        let manager = HotkeyManager(keyCode: ConfigManager.shared.hotkeyKeyCode)
        manager.onPress = { [weak self] in self?.handleHotkeyPress() }
        manager.onRelease = { [weak self] in self?.handleHotkeyRelease() }
        manager.onCancel = { [weak self] in self?.handleHotkeyCancel() }

        if manager.start() {
            hotkeyManager = manager
            statusBar?.updateHotkeyStatus(enabled: true)
            statusBar?.showPermissionHint(false)
            print("[TypeFlow] setupHotkey: success — event tap active")
            return true
        } else {
            statusBar?.updateHotkeyStatus(enabled: false)
            print("[TypeFlow] setupHotkey: failed — CGEvent.tapCreate returned nil (AXIsProcessTrusted=\(AXIsProcessTrusted()))")
            return false
        }
    }

    private func startPermissionPolling() {
        permissionPollTask?.cancel()
        var lastAXStatus = AXIsProcessTrusted()

        permissionPollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }

                let currentAX = AXIsProcessTrusted()
                if currentAX != lastAXStatus {
                    print("[TypeFlow] AXIsProcessTrusted changed: \(lastAXStatus) → \(currentAX)")
                    lastAXStatus = currentAX
                }

                if currentAX {
                    if setupHotkey() {
                        print("[TypeFlow] Permission recovery complete — hotkey active")
                        return
                    }
                    print("[TypeFlow] AXIsProcessTrusted=true but tapCreate failed — will retry in 2s")
                }
            }
        }
    }

    private func retryPermissionCheck() {
        let axTrusted = AXIsProcessTrusted()
        print("[TypeFlow] Manual retry: AXIsProcessTrusted=\(axTrusted)")

        if axTrusted && setupHotkey() {
            print("[TypeFlow] Manual retry: hotkey setup succeeded")
            permissionPollTask?.cancel()
            permissionPollTask = nil
            return
        }

        statusBar?.updateHotkeyStatus(enabled: false)
        statusBar?.showPermissionHint(true)

        if permissionPollTask == nil {
            startPermissionPolling()
        }

        if !axTrusted {
            print("[TypeFlow] Manual retry: accessibility still not granted")
        } else {
            print("[TypeFlow] Manual retry: AX trusted but tapCreate still failing")
        }
    }

    // MARK: - Microphone Permission

    /// Returns true if mic is authorized and recording can proceed.
    private func ensureMicrophonePermission() -> Bool {
        if micPermissionGranted { return true }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            micPermissionGranted = true
            statusBar?.showMicPermissionHint(false)
            return true
        case .notDetermined:
            print("[TypeFlow] Microphone: requesting permission — press hotkey again after granting")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.micPermissionGranted = granted
                    if granted {
                        print("[TypeFlow] Microphone permission granted")
                        self?.statusBar?.showMicPermissionHint(false)
                    } else {
                        print("[TypeFlow] Microphone permission denied by user")
                        self?.statusBar?.showMicPermissionHint(true)
                    }
                }
            }
            return false
        case .denied, .restricted:
            print("[TypeFlow] Microphone: \(status.label) — cannot record")
            appState.showError("Microphone permission required")
            statusBar?.showMicPermissionHint(true)
            return false
        @unknown default:
            return true
        }
    }

    // MARK: - Recording Flow

    private func handleHotkeyPress() {
        guard ensureMicrophonePermission() else { return }
        guard appState.startRecording() else { return }

        do {
            try audioRecorder.startRecording()
            cancelIndicatorHide()
            floatingIndicator?.show(phase: .recording)
            print("[TypeFlow] Recording started")

            let maxDuration = ConfigManager.shared.maxRecordingDuration
            maxDurationTask = Task {
                try? await Task.sleep(for: .seconds(maxDuration))
                guard !Task.isCancelled else { return }
                print("[TypeFlow] Auto-stopping: max duration reached")
                self.handleHotkeyRelease()
            }
        } catch {
            appState.showError("Recording failed: \(error.localizedDescription)")
            floatingIndicator?.show(phase: .error(error.localizedDescription))
            scheduleIndicatorHide()
            print("[TypeFlow] Recording failed: \(error)")
        }
    }

    private func handleHotkeyRelease() {
        maxDurationTask?.cancel()
        maxDurationTask = nil

        // Always stop audio engine first
        let samples = audioRecorder.stopRecording()

        guard let duration = appState.stopRecording() else {
            // Too short (<0.5s) or not in recording state
            floatingIndicator?.hide()
            return
        }

        // Empty samples = audio capture failure
        if samples.isEmpty {
            print("[TypeFlow] Recording stopped but got 0 samples")
            appState.showError("No audio captured")
            floatingIndicator?.show(phase: .error("No audio"))
            scheduleIndicatorHide()
            return
        }

        print("[TypeFlow] Recording stopped: \(String(format: "%.2f", duration))s, \(samples.count) samples")
        cancelIndicatorHide()
        floatingIndicator?.show(phase: .processing)

        guard let engine = whisperEngine else {
            appState.showError("Whisper engine not initialized")
            floatingIndicator?.show(phase: .error("Engine error"))
            scheduleIndicatorHide()
            return
        }

        Task {
            do {
                let rawText = try await engine.transcribe(samples: samples)
                print("[TypeFlow] STT: \(rawText)")

                let polished = await llmService.polish(text: rawText)
                if polished != rawText {
                    print("[TypeFlow] LLM: \(polished)")
                } else {
                    print("[TypeFlow] LLM: skipped or unchanged")
                }

                await textOutputManager.output(text: polished)
                floatingIndicator?.hide()
                appState.finishProcessing()
            } catch {
                print("[TypeFlow] Processing failed: \(error)")
                appState.showError("\(error)")
                floatingIndicator?.show(phase: .error("\(error)"))
                scheduleIndicatorHide()
            }
        }
    }

    private func handleHotkeyCancel() {
        maxDurationTask?.cancel()
        maxDurationTask = nil
        _ = audioRecorder.stopRecording()
        appState.reset()
        floatingIndicator?.hide()
        print("[TypeFlow] Recording cancelled (combo key detected)")
    }

    private func scheduleIndicatorHide() {
        indicatorHideTask?.cancel()
        indicatorHideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            floatingIndicator?.hide()
        }
    }

    private func cancelIndicatorHide() {
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
    }
}

// MARK: - AVAuthorizationStatus label

extension AVAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }
}
