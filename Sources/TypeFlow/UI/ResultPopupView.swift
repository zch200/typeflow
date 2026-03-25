import AppKit

@MainActor
final class ResultPopup: NSObject {
    private var panel: NSPanel?
    private let text: String
    private let hint: String?

    init(text: String, hint: String? = nil) {
        self.text = text
        self.hint = hint
        super.init()
    }

    func show() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = hint != nil ? "TypeFlow — \(hint!)" : "TypeFlow"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))

        // Scroll view + text view
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 56, width: 388, height: 148))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 388, height: 148))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        container.addSubview(scrollView)

        // Copy button (default = Enter)
        let copyBtn = NSButton(frame: NSRect(x: 220, y: 12, width: 88, height: 32))
        copyBtn.title = "Copy"
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "\r"
        copyBtn.target = self
        copyBtn.action = #selector(copyAndClose)
        container.addSubview(copyBtn)

        // Close button (Escape)
        let closeBtn = NSButton(frame: NSRect(x: 316, y: 12, width: 88, height: 32))
        closeBtn.title = "Close"
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.target = self
        closeBtn.action = #selector(closePanel)
        container.addSubview(closeBtn)

        panel.contentView = container

        // Position: center on mouse's current screen
        let mousePos = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(mousePos, $0.frame, false)
        }) ?? NSScreen.main
        if let screen = targetScreen {
            let vis = screen.visibleFrame
            let x = vis.midX - panel.frame.width / 2
            let y = vis.midY - panel.frame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Force visible: makeKey + orderFrontRegardless + activate app
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel

        print("[TypeFlow] Popup: frame=\(panel.frame) screen=\(targetScreen?.frame.debugDescription ?? "nil") visible=\(panel.isVisible)")
    }

    func close() {
        panel?.close()
        panel = nil
    }

    @objc private func copyAndClose() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("[TypeFlow] Popup: copied to clipboard")
        close()
    }

    @objc private func closePanel() {
        close()
    }
}
