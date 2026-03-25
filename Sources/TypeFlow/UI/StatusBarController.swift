import AppKit
import Combine

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellable: AnyCancellable?
    private var hotkeyMenuItem: NSMenuItem?
    private var permissionMenuItem: NSMenuItem?
    private var retryMenuItem: NSMenuItem?
    private var micPermissionMenuItem: NSMenuItem?

    /// Called when user clicks "Retry Permission Check"
    var onRetryPermission: (() -> Void)?

    init(appState: AppState) {
        super.init()
        configureButton()
        configureMenu()

        // Startup diagnostics
        let button = statusItem.button
        print("[TypeFlow] StatusBar: button=\(button != nil), image=\(button?.image != nil), title=\"\(button?.title ?? "nil")\", menu=\(statusItem.menu != nil)")

        cancellable = appState.$phase.sink { [weak self] phase in
            Task { @MainActor [weak self] in
                self?.updateForPhase(phase)
            }
        }
    }

    // MARK: - Button

    private func configureButton() {
        guard let button = statusItem.button else {
            print("[TypeFlow] ⚠ statusItem.button is nil — menu bar icon will not appear")
            return
        }
        setButtonImage(symbolName: "mic.fill", fallbackTitle: "TF")
        print("[TypeFlow] StatusBar button configured: image=\(button.image != nil), title=\"\(button.title)\"")
    }

    private func setButtonImage(symbolName: String, fallbackTitle: String) {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TypeFlow") {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = fallbackTitle
            print("[TypeFlow] ⚠ SF Symbol '\(symbolName)' unavailable, using text fallback '\(fallbackTitle)'")
        }
    }

    // MARK: - Menu

    private func configureMenu() {
        let menu = NSMenu()

        // Hotkey status (tag 300)
        let hotkeyItem = NSMenuItem(title: "Hotkey: Checking...", action: nil, keyEquivalent: "")
        hotkeyItem.tag = 300
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        hotkeyMenuItem = hotkeyItem

        // App phase status (tag 100)
        let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Permission action (tag 200, hidden when granted)
        let permItem = NSMenuItem(
            title: "Grant Accessibility Permission...",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permItem.target = self
        permItem.isHidden = true
        permItem.tag = 200
        menu.addItem(permItem)
        permissionMenuItem = permItem

        // Retry permission check (tag 201, hidden when granted)
        let retryItem = NSMenuItem(
            title: "Retry Permission Check",
            action: #selector(retryPermission),
            keyEquivalent: ""
        )
        retryItem.target = self
        retryItem.isHidden = true
        retryItem.tag = 201
        menu.addItem(retryItem)
        retryMenuItem = retryItem

        // Microphone permission (tag 202, hidden when granted)
        let micItem = NSMenuItem(
            title: "Grant Microphone Permission...",
            action: #selector(openMicrophoneSettings),
            keyEquivalent: ""
        )
        micItem.target = self
        micItem.isHidden = true
        micItem.tag = 202
        menu.addItem(micItem)
        micPermissionMenuItem = micItem

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit TypeFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - State Updates

    private func updateForPhase(_ phase: AppPhase) {
        guard let menuItem = statusItem.menu?.item(withTag: 100) else { return }
        switch phase {
        case .idle:
            menuItem.title = "Status: Idle"
            setButtonImage(symbolName: "mic.fill", fallbackTitle: "TF")
        case .recording:
            menuItem.title = "Status: Recording..."
            setButtonImage(symbolName: "mic.badge.plus", fallbackTitle: "REC")
        case .processing:
            menuItem.title = "Status: Processing..."
            setButtonImage(symbolName: "ellipsis.circle", fallbackTitle: "...")
        case .error(let msg):
            menuItem.title = "Error: \(msg)"
            setButtonImage(symbolName: "exclamationmark.triangle", fallbackTitle: "!")
        }
    }

    func updateHotkeyStatus(enabled: Bool) {
        if enabled {
            hotkeyMenuItem?.title = "Hotkey: Left Option (Active)"
        } else {
            hotkeyMenuItem?.title = "Hotkey: Disabled (Permission Required)"
        }
    }

    func showPermissionHint(_ show: Bool) {
        permissionMenuItem?.isHidden = !show
        retryMenuItem?.isHidden = !show
    }

    func showMicPermissionHint(_ show: Bool) {
        micPermissionMenuItem?.isHidden = !show
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func retryPermission() {
        onRetryPermission?()
    }

    @objc private func openSettings() {
        print("[TypeFlow] Settings not yet implemented")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
