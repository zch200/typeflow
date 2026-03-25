import AppKit

@MainActor
final class ResultPopup: NSObject {
    private var panel: NSWindow?
    private var titleLabel: NSTextField?
    private var textView: NSTextView?
    private var currentText = ""

    private func ensureWindow() {
        guard panel == nil else { return }

        print("[TypeFlow] Popup: creating window")
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "TypeFlow"
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.layer?.borderWidth = 1

        let titleLabel = NSTextField(labelWithString: "TypeFlow")
        titleLabel.frame = NSRect(x: 16, y: 190, width: 280, height: 20)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        container.addSubview(titleLabel)
        self.titleLabel = titleLabel

        // Scroll view + text view
        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 52, width: 388, height: 126))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 388, height: 126))
        textView.string = ""
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        container.addSubview(scrollView)
        self.textView = textView

        // Copy button (default = Enter)
        let copyBtn = NSButton(frame: NSRect(x: 220, y: 12, width: 88, height: 28))
        copyBtn.title = "Copy"
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "\r"
        copyBtn.target = self
        copyBtn.action = #selector(copyAndClose)
        container.addSubview(copyBtn)

        // Close button (Escape)
        let closeBtn = NSButton(frame: NSRect(x: 316, y: 12, width: 88, height: 28))
        closeBtn.title = "Close"
        closeBtn.bezelStyle = .rounded
        closeBtn.keyEquivalent = "\u{1b}"
        closeBtn.target = self
        closeBtn.action = #selector(closePanel)
        container.addSubview(closeBtn)

        panel.contentView = container
        self.panel = panel
        print("[TypeFlow] Popup: content configured")
    }

    func show(text: String, hint: String? = nil) {
        ensureWindow()
        guard let panel else {
            print("[TypeFlow] Popup: show aborted — window unavailable")
            return
        }

        currentText = text
        titleLabel?.stringValue = hint ?? "TypeFlow"
        textView?.string = text

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

        print("[TypeFlow] Popup: prepared frame=\(panel.frame.debugDescription) screen=\(targetScreen?.frame.debugDescription ?? "nil")")
        panel.orderFrontRegardless()
        print("[TypeFlow] Popup: displayed visible=\(panel.isVisible) key=\(panel.isKeyWindow)")
    }

    func close() {
        panel?.orderOut(nil)
    }

    @objc private func copyAndClose() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentText, forType: .string)
        print("[TypeFlow] Popup: copied to clipboard")
        close()
    }

    @objc private func closePanel() {
        close()
    }
}
