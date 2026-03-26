import AppKit
import ApplicationServices
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private var statusBar: StatusBarController?
    private var hotkeyManager: HotkeyManager?
    private let audioRecorder = AudioRecorder()
    private var speechEngine: (any SpeechEngine)?
    private let llmService = LLMService()
    private let textOutputManager = TextOutputManager()
    private var floatingIndicator: FloatingIndicator?
    private var maxDurationTask: Task<Void, Never>?
    private var permissionPollTask: Task<Void, Never>?
    private var indicatorHideTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var isTerminating = false
    private var micPermissionGranted = false
    private lazy var settingsController = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        // Prompt system authorization dialog if not yet trusted.
        // The key is kAXTrustedCheckOptionPrompt ("AXTrustedCheckOptionPrompt").
        let axTrusted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[TypeFlow] Launch: AXIsProcessTrusted=\(axTrusted), microphoneStatus=\(micStatus.label)")

        statusBar = StatusBarController(appState: appState)
        statusBar?.onRetryPermission = { [weak self] in self?.retryPermissionCheck() }
        statusBar?.onOpenSettings = { [weak self] in self?.openSettings() }
        floatingIndicator = FloatingIndicator()

        // Request mic permission early — macOS may kill the process on first
        // grant, so trigger this during launch rather than mid-recording.
        switch micStatus {
        case .authorized:
            micPermissionGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.micPermissionGranted = granted
                    if granted {
                        print("[TypeFlow] Microphone permission granted (startup)")
                        self?.statusBar?.showMicPermissionHint(false)
                    } else {
                        print("[TypeFlow] Microphone permission denied (startup)")
                        self?.statusBar?.showMicPermissionHint(true)
                    }
                }
            }
        case .denied, .restricted:
            statusBar?.showMicPermissionHint(true)
        @unknown default:
            break
        }

        // Initialize speech engine
        speechEngine = createSpeechEngine()
        if ConfigManager.shared.speechEngineType == .whisperLocal {
            let modelPath = ConfigManager.shared.modelPath
            if !FileManager.default.fileExists(atPath: modelPath) {
                print("[TypeFlow] Warning: model not found at \(modelPath)")
                print("[TypeFlow] Download a whisper model and place it there to enable transcription")
            }
        }

        // Wire settings callbacks
        setupSettingsCallbacks()

        if axTrusted {
            if !setupHotkey() {
                // AX says trusted but tap failed — binary signature changed
                // after rebuild. Reset stale TCC entry and re-prompt.
                print("[TypeFlow] AXIsProcessTrusted=true but event tap failed — signature mismatch")
                resetStaleAccessibilityPermission()
                statusBar?.showPermissionHint(true, stale: true)
                startPermissionPolling()
            }
        } else {
            print("[TypeFlow] Accessibility permission not granted — hotkey disabled")
            statusBar?.updateHotkeyStatus(enabled: false)
            statusBar?.showPermissionHint(true)
            startPermissionPolling()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating {
            return .terminateNow
        }

        isTerminating = true
        print("[TypeFlow] Shutdown: begin")

        hotkeyManager?.stop()
        permissionPollTask?.cancel()
        permissionPollTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        indicatorHideTask?.cancel()
        indicatorHideTask = nil
        processingTask?.cancel()
        _ = audioRecorder.stopRecording()
        floatingIndicator?.hide()

        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            if let engine = self.speechEngine {
                print("[TypeFlow] Shutdown: freeing speech engine")
                await engine.shutdown()
            }

            print("[TypeFlow] Shutdown: complete")
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
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

    // MARK: - Edit Menu (enables Cmd+V / Cmd+C in text fields for LSUIElement app)

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Settings

    private func openSettings() {
        settingsController.showWindow()
    }

    private func setupSettingsCallbacks() {
        settingsController.onSettingsOpened = { [weak self] in
            self?.hotkeyManager?.pause()
        }
        settingsController.onSettingsClosed = { [weak self] in
            self?.hotkeyManager?.resume()
        }
        settingsController.onHotkeyChanged = { [weak self] _ in
            guard let self else { return }
            self.hotkeyManager?.stop()
            self.hotkeyManager = nil
            if AXIsProcessTrusted() {
                self.setupHotkey()
                // Settings window is still open → keep the new manager paused
                self.hotkeyManager?.pause()
            }
        }
        settingsController.onSpeechEngineChanged = { [weak self] in
            guard let self else { return }
            let oldEngine = self.speechEngine
            self.speechEngine = self.createSpeechEngine()
            print("[TypeFlow] Speech engine switched to \(ConfigManager.shared.speechEngineType)")
            if let oldEngine {
                Task {
                    // Wait for any in-flight transcription before shutting down old engine
                    await self.processingTask?.value
                    await oldEngine.shutdown()
                }
            }
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

        guard let engine = speechEngine else {
            appState.showError("Speech engine not initialized")
            floatingIndicator?.show(phase: .error("Engine error"))
            scheduleIndicatorHide()
            return
        }

        processingTask = Task {
            do {
                let rawText = try await engine.transcribe(samples: samples)
                print("[TypeFlow] STT: \(rawText)")

                let polished = await llmService.polish(text: rawText)
                if polished != rawText {
                    print("[TypeFlow] LLM: \(polished)")
                } else {
                    print("[TypeFlow] LLM: skipped or unchanged")
                }

                print("[TypeFlow] output begin — text length=\(polished.count)")
                await textOutputManager.output(text: polished)
                print("[TypeFlow] output end")

                floatingIndicator?.hide()
                print("[TypeFlow] indicator hidden (phase: processing → idle)")

                appState.finishProcessing()
                print("[TypeFlow] phase → idle")
            } catch {
                print("[TypeFlow] Processing failed: \(error)")
                appState.showError("\(error)")
                floatingIndicator?.show(phase: .error("\(error)"))
                scheduleIndicatorHide()
            }

            processingTask = nil
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

    // MARK: - Stale Permission Recovery

    /// When AXIsProcessTrusted() returns true but CGEvent.tapCreate fails, the code
    /// signature has changed since the last authorization (common after rebuild).
    /// Clear the stale TCC entry so a fresh authorization prompt appears.
    private func resetStaleAccessibilityPermission() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.typeflow.app"
        print("[TypeFlow] Resetting stale TCC entry for \(bundleId)")

        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", bundleId]
        tccutil.standardOutput = FileHandle.nullDevice
        tccutil.standardError = FileHandle.nullDevice

        do {
            try tccutil.run()
            tccutil.waitUntilExit()
            print("[TypeFlow] tccutil exit code: \(tccutil.terminationStatus)")
        } catch {
            print("[TypeFlow] tccutil failed: \(error)")
            return
        }

        // Re-prompt: if reset worked, AXIsProcessTrusted() is now false
        // and this will show the system authorization dialog
        let prompted = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
        print("[TypeFlow] After TCC reset: AXIsProcessTrusted=\(prompted)")
    }

    // MARK: - Speech Engine Factory

    private func createSpeechEngine() -> any SpeechEngine {
        switch ConfigManager.shared.speechEngineType {
        case .whisperLocal:
            return WhisperEngine(modelPath: ConfigManager.shared.modelPath)
        case .qwenCloud:
            return QwenCloudEngine(
                endpoint: ConfigManager.shared.cloudSpeechEndpoint,
                model: ConfigManager.shared.cloudSpeechModel,
                apiKey: ConfigManager.shared.cloudSpeechApiKey ?? ""
            )
        }
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
