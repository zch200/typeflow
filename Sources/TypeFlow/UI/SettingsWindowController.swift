import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    private var window: NSWindow?

    // General tab
    private var hotkeyButton: NSButton?
    private var strategyPopup: NSPopUpButton?

    // Speech tab
    private var modelPathField: NSTextField?
    private var modelStatusLabel: NSTextField?

    // LLM tab
    private var endpointField: NSTextField?
    private var llmModelField: NSTextField?
    private var apiKeyField: NSSecureTextField?
    private var systemPromptTextView: NSTextView?

    // Hotkey recording
    private var isRecordingHotkey = false
    private nonisolated(unsafe) var hotkeyEventMonitor: Any?

    // Callbacks
    var onHotkeyChanged: ((UInt16) -> Void)?
    var onModelPathChanged: ((String) -> Void)?
    var onSettingsOpened: (() -> Void)?
    var onSettingsClosed: (() -> Void)?

    func showWindow() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        onSettingsOpened?()

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "TypeFlow Settings"
        w.delegate = self
        w.isReleasedWhenClosed = false

        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        tabView.autoresizingMask = [.width, .height]
        tabView.addTabViewItem(createGeneralTab())
        tabView.addTabViewItem(createSpeechTab())
        tabView.addTabViewItem(createLLMTab())

        w.contentView = tabView
        self.window = w

        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            self.stopHotkeyRecording(cancelled: true)
            self.saveAllLLMFields()
            self.onSettingsClosed?()
        }
    }

    // MARK: - NSTextFieldDelegate (LLM fields save on focus-out)

    nonisolated func controlTextDidEndEditing(_ obj: Notification) {
        Task { @MainActor [weak self] in
            self?.saveAllLLMFields()
        }
    }

    // MARK: - NSTextViewDelegate (system prompt saves on focus-out)

    nonisolated func textDidEndEditing(_ notification: Notification) {
        Task { @MainActor [weak self] in
            if let prompt = self?.systemPromptTextView?.string, !prompt.isEmpty {
                ConfigManager.shared.llmSystemPrompt = prompt
                print("[TypeFlow] Settings: system prompt saved")
            }
        }
    }

    // MARK: - LLM Save Helpers

    private func saveLLMField(_ field: NSTextField) {
        if field === endpointField {
            if !field.stringValue.isEmpty {
                ConfigManager.shared.llmEndpoint = field.stringValue
                print("[TypeFlow] Settings: endpoint saved")
            }
        } else if field === llmModelField {
            if !field.stringValue.isEmpty {
                ConfigManager.shared.llmModel = field.stringValue
                print("[TypeFlow] Settings: model saved")
            }
        } else if field === apiKeyField {
            let key = field.stringValue
            ConfigManager.shared.llmApiKey = key.isEmpty ? nil : key
            print("[TypeFlow] Settings: API key saved")
        }
    }

    /// Safety net: save all fields (called on window close)
    private func saveAllLLMFields() {
        if let f = endpointField { saveLLMField(f) }
        if let f = llmModelField { saveLLMField(f) }
        if let f = apiKeyField { saveLLMField(f) }
        if let prompt = systemPromptTextView?.string, !prompt.isEmpty {
            ConfigManager.shared.llmSystemPrompt = prompt
        }
        print("[TypeFlow] Settings: all fields saved (window close)")
    }

    // MARK: - General Tab

    private func createGeneralTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "general")
        item.label = "General"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 370))

        // Hotkey
        view.addSubview(makeLabel("Hotkey:", x: 20, y: 310))

        let btn = NSButton(frame: NSRect(x: 150, y: 306, width: 220, height: 28))
        btn.title = ConfigManager.hotkeyDisplayName(ConfigManager.shared.hotkeyKeyCode)
        btn.bezelStyle = .rounded
        btn.target = self
        btn.action = #selector(toggleHotkeyRecording)
        view.addSubview(btn)
        hotkeyButton = btn

        view.addSubview(makeHint(
            "Click to record, press a modifier key to set, Escape to cancel",
            x: 150, y: 286, width: 340
        ))

        // Separator
        let sep = NSBox(frame: NSRect(x: 20, y: 270, width: 480, height: 1))
        sep.boxType = .separator
        view.addSubview(sep)

        // Strategy
        view.addSubview(makeLabel("Focus Unavailable:", x: 20, y: 237))

        let popup = NSPopUpButton(frame: NSRect(x: 150, y: 233, width: 260, height: 28))
        popup.addItems(withTitles: [
            "Blind Paste Only",
            "Blind Paste → Popup",
            "Popup Only",
        ])
        popup.selectItem(at: ConfigManager.shared.unavailableFocusStrategy.rawValue)
        popup.target = self
        popup.action = #selector(strategyChanged(_:))
        view.addSubview(popup)
        strategyPopup = popup

        view.addSubview(makeHint(
            "Global default when AX focus is unavailable.\nPer-app overrides (Codex, WeChat) take priority.",
            x: 150, y: 200, width: 340, height: 30
        ))

        item.view = view
        return item
    }

    // MARK: - Speech Tab

    private func createSpeechTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "speech")
        item.label = "Speech"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 370))

        view.addSubview(makeLabel("Model File:", x: 20, y: 310))

        let pathField = NSTextField(frame: NSRect(x: 150, y: 308, width: 250, height: 24))
        pathField.stringValue = ConfigManager.shared.modelPath
        pathField.isEditable = false
        pathField.isSelectable = true
        pathField.font = .systemFont(ofSize: 11)
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.cell?.truncatesLastVisibleLine = true
        view.addSubview(pathField)
        modelPathField = pathField

        let browseBtn = NSButton(frame: NSRect(x: 408, y: 306, width: 90, height: 28))
        browseBtn.title = "Browse..."
        browseBtn.bezelStyle = .rounded
        browseBtn.target = self
        browseBtn.action = #selector(browseModelFile)
        view.addSubview(browseBtn)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 150, y: 284, width: 340, height: 16)
        statusLabel.font = .systemFont(ofSize: 11)
        view.addSubview(statusLabel)
        modelStatusLabel = statusLabel
        updateModelStatus()

        view.addSubview(makeHint(
            "Select a whisper.cpp model file (.bin).\nDownload from huggingface.co/ggerganov/whisper.cpp",
            x: 150, y: 250, width: 340, height: 30
        ))

        item.view = view
        return item
    }

    // MARK: - LLM Tab

    private func createLLMTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "llm")
        item.label = "LLM"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 370))
        var y: CGFloat = 320

        // Endpoint
        view.addSubview(makeLabel("Endpoint:", x: 20, y: y))
        let epField = NSTextField(frame: NSRect(x: 130, y: y - 2, width: 370, height: 24))
        epField.stringValue = ConfigManager.shared.llmEndpoint
        epField.font = .systemFont(ofSize: 13)
        epField.placeholderString = "https://api.example.com/compatible-mode"
        epField.delegate = self
        view.addSubview(epField)
        endpointField = epField
        y -= 36

        // Model
        view.addSubview(makeLabel("Model:", x: 20, y: y))
        let mField = NSTextField(frame: NSRect(x: 130, y: y - 2, width: 370, height: 24))
        mField.stringValue = ConfigManager.shared.llmModel
        mField.font = .systemFont(ofSize: 13)
        mField.placeholderString = "qwen-turbo"
        mField.delegate = self
        view.addSubview(mField)
        llmModelField = mField
        y -= 36

        // API Key
        view.addSubview(makeLabel("API Key:", x: 20, y: y))
        let akField = NSSecureTextField(frame: NSRect(x: 130, y: y - 2, width: 370, height: 24))
        akField.stringValue = ConfigManager.shared.llmApiKey ?? ""
        akField.font = .systemFont(ofSize: 13)
        akField.placeholderString = "sk-..."
        akField.delegate = self
        view.addSubview(akField)
        apiKeyField = akField
        y -= 8
        view.addSubview(makeHint("Stored in Keychain, not in plain text", x: 130, y: y - 16, width: 340))
        y -= 36

        // Separator
        let sep = NSBox(frame: NSRect(x: 20, y: y, width: 480, height: 1))
        sep.boxType = .separator
        view.addSubview(sep)
        y -= 20

        // System Prompt
        view.addSubview(makeLabel("System Prompt:", x: 20, y: y))

        let scrollView = NSScrollView(frame: NSRect(x: 130, y: 50, width: 370, height: y - 30))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 355, height: y - 30))
        textView.string = ConfigManager.shared.llmSystemPrompt
        textView.font = .systemFont(ofSize: 12)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width, .height]
        textView.delegate = self
        scrollView.documentView = textView
        view.addSubview(scrollView)
        systemPromptTextView = textView

        // Reset prompt button
        let resetBtn = NSButton(frame: NSRect(x: 20, y: 16, width: 140, height: 28))
        resetBtn.title = "Reset Prompt"
        resetBtn.bezelStyle = .rounded
        resetBtn.target = self
        resetBtn.action = #selector(resetSystemPrompt)
        view.addSubview(resetBtn)

        item.view = view
        return item
    }

    // MARK: - Hotkey Recording

    @objc private func toggleHotkeyRecording() {
        if isRecordingHotkey {
            stopHotkeyRecording(cancelled: true)
        } else {
            startHotkeyRecording()
        }
    }

    private func startHotkeyRecording() {
        isRecordingHotkey = true
        hotkeyButton?.title = "Press a modifier key..."

        hotkeyEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            // Extract values from NSEvent before crossing into MainActor
            let eventType = event.type
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags

            let consumed: Bool = MainActor.assumeIsolated {
                guard let self, self.isRecordingHotkey else { return false }

                // Escape cancels
                if eventType == .keyDown && keyCode == 53 {
                    self.stopHotkeyRecording(cancelled: true)
                    return true
                }

                guard eventType == .flagsChanged else { return false }

                let kc = keyCode
                let validKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
                guard validKeys.contains(kc) else { return false }

                // Only accept press (not release)
                let pressed: Bool
                switch kc {
                case 58, 61: pressed = modifierFlags.contains(.option)
                case 56, 60: pressed = modifierFlags.contains(.shift)
                case 59, 62: pressed = modifierFlags.contains(.control)
                case 55, 54: pressed = modifierFlags.contains(.command)
                case 57: pressed = modifierFlags.contains(.capsLock)
                case 63: pressed = modifierFlags.contains(.function)
                default: pressed = false
                }
                guard pressed else { return false }

                // Accept this key
                self.isRecordingHotkey = false
                self.removeHotkeyEventMonitor()
                ConfigManager.shared.hotkeyKeyCode = kc
                self.hotkeyButton?.title = ConfigManager.hotkeyDisplayName(kc)
                self.onHotkeyChanged?(kc)
                print("[TypeFlow] Settings: hotkey changed to \(ConfigManager.hotkeyDisplayName(kc))")
                return true
            }
            return consumed ? nil : event
        }
    }

    private func stopHotkeyRecording(cancelled: Bool) {
        guard isRecordingHotkey || hotkeyEventMonitor != nil else { return }
        isRecordingHotkey = false
        removeHotkeyEventMonitor()
        if cancelled {
            hotkeyButton?.title = ConfigManager.hotkeyDisplayName(ConfigManager.shared.hotkeyKeyCode)
        }
    }

    private func removeHotkeyEventMonitor() {
        if let monitor = hotkeyEventMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyEventMonitor = nil
        }
    }

    // MARK: - Actions

    @objc private func strategyChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if let strategy = UnavailableFocusStrategy(rawValue: index) {
            ConfigManager.shared.unavailableFocusStrategy = strategy
            print("[TypeFlow] Settings: strategy → \(strategy)")
        }
    }

    @objc private func browseModelFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Whisper Model"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        // Start in current model's directory
        let currentDir = (ConfigManager.shared.modelPath as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: currentDir) {
            panel.directoryURL = URL(fileURLWithPath: currentDir)
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let path = url.path
                ConfigManager.shared.modelPath = path
                self?.modelPathField?.stringValue = path
                self?.updateModelStatus()
                self?.onModelPathChanged?(path)
                print("[TypeFlow] Settings: model → \(path)")
            }
        }
    }

    @objc private func resetSystemPrompt() {
        systemPromptTextView?.string = ConfigManager.defaultSystemPrompt
        ConfigManager.shared.llmSystemPrompt = ConfigManager.defaultSystemPrompt
        print("[TypeFlow] Settings: system prompt reset to default")
    }

    // MARK: - Helpers

    private func updateModelStatus() {
        let path = ConfigManager.shared.modelPath
        if FileManager.default.fileExists(atPath: path) {
            modelStatusLabel?.stringValue = "✓ Model found"
            modelStatusLabel?.textColor = .systemGreen
        } else {
            modelStatusLabel?.stringValue = "✗ Model not found at this path"
            modelStatusLabel?.textColor = .systemRed
        }
    }

    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: x, y: y, width: 120, height: 20)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .right
        return label
    }

    private func makeHint(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 340, height: CGFloat = 16) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.frame = NSRect(x: x, y: y, width: width, height: height)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        return hint
    }
}
