import AppKit
import ApplicationServices

@MainActor
final class TextOutputManager {
    private let resultPopup = ResultPopup()

    // MARK: - Focus Classification

    private enum FocusContext {
        case editableText(element: AXUIElement, bundleId: String?, confidence: EditConfidence)
        case nonEditable(bundleId: String?, role: String?)
        case unavailable(reason: String, bundleId: String?)
    }

    private enum EditConfidence: CustomStringConvertible {
        case high
        case medium

        var description: String {
            switch self {
            case .high: "high"
            case .medium: "medium"
            }
        }
    }

    // MARK: - Public

    func output(text: String) async {
        let context = classifyFocus()

        switch context {
        case .editableText(let element, let bundleId, let confidence):
            print("[TypeFlow] Output: editableText (bundle=\(bundleId ?? "?"), confidence=\(confidence))")

            if writeViaSelectedText(element, text: text) { return }
            if writeViaValueSplice(element, text: text) { return }
            if await pasteWithVerification(text, element: element, confidence: confidence) { return }

            print("[TypeFlow] Output: all write methods failed → popup")
            showPopup(text)

        case .nonEditable(let bundleId, let role):
            print("[TypeFlow] Output: nonEditable (bundle=\(bundleId ?? "?"), role=\(role ?? "?")) → popup")
            showPopup(text)

        case .unavailable(let reason, let bundleId):
            let strategy = ConfigManager.shared.strategyForApp(bundleId)
            print("[TypeFlow] Output: unavailable (\(reason)) strategy=\(strategy) bundle=\(bundleId ?? "nil")")

            switch strategy {
            case .blindPasteOnly:
                if await blindPaste(text) {
                    print("[TypeFlow] Output: [blind-paste] Cmd+V sent (blindPasteOnly) blindPaste=true popup=false")
                    return
                }
                print("[TypeFlow] Output: [blind-paste] CGEvent failed (blindPasteOnly) blindPaste=false popup=true")
                showPopup(text)

            case .blindPasteThenPopup:
                let pasted = await blindPaste(text)
                // Small delay so Cmd+V reaches target app before popup steals focus
                if pasted { try? await Task.sleep(for: .milliseconds(100)) }
                print("[TypeFlow] Output: [blind-paste+popup] (blindPasteThenPopup) blindPaste=\(pasted) popup=true")
                showPopup(text, hint: pasted ? "已尝试粘贴到前台应用" : nil)

            case .popupOnly:
                print("[TypeFlow] Output: [popup] direct (popupOnly) blindPaste=false popup=true")
                showPopup(text)
            }
        }
    }

    // MARK: - Focus Classification Logic

    private func classifyFocus() -> FocusContext {
        let systemWide = AXUIElementCreateSystemWide()

        // --- Focused app (with NSWorkspace fallback) ---
        var appRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &appRef
        )

        let app: AXUIElement
        let bundleId: String?

        if appErr == .success, let appRef {
            // Safe: AX guarantees AXUIElement on .success; nil guarded above
            app = appRef as! AXUIElement
            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        } else {
            // Fallback: NSWorkspace → AXUIElementCreateApplication
            print("[TypeFlow] Focus: kAXFocusedApplication failed (AXError=\(appErr.rawValue)), trying NSWorkspace fallback")
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return .unavailable(
                    reason: "no focused app (AXError=\(appErr.rawValue), NSWorkspace frontmost=nil)",
                    bundleId: nil
                )
            }
            bundleId = frontApp.bundleIdentifier
            app = AXUIElementCreateApplication(frontApp.processIdentifier)
            print("[TypeFlow] Focus: NSWorkspace fallback → pid=\(frontApp.processIdentifier) bundle=\(bundleId ?? "?")")
        }

        // --- Focused element ---
        var elemRef: CFTypeRef?
        let elemErr = AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &elemRef
        )
        guard elemErr == .success, let elemRef else {
            return .unavailable(
                reason: "no focused element (AXError=\(elemErr.rawValue), bundle=\(bundleId ?? "?"))",
                bundleId: bundleId
            )
        }
        // Safe: guarded .success + non-nil
        let element = elemRef as! AXUIElement

        // --- Collect AX attributes ---
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        let editable = axBool(element, "AXEditable")
        let hasSelectedText = axExists(element, kAXSelectedTextAttribute)
        let selectedTextSettable = axIsSettable(element, kAXSelectedTextAttribute)
        let hasRange = axExists(element, kAXSelectedTextRangeAttribute)
        let hasValue = axExists(element, kAXValueAttribute)

        print("[TypeFlow] Focus: bundle=\(bundleId ?? "?") role=\(role ?? "nil") subrole=\(subrole ?? "nil") editable=\(editable.map(String.init(describing:)) ?? "nil") selText=\(hasSelectedText)/settable=\(selectedTextSettable) range=\(hasRange) value=\(hasValue)")

        // --- Classification ---
        let knownTextRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        ]

        if let role, knownTextRoles.contains(role) {
            if editable == false {
                return .nonEditable(bundleId: bundleId, role: role)
            }
            return .editableText(element: element, bundleId: bundleId, confidence: .high)
        }

        if editable == true, (hasSelectedText || hasValue) {
            return .editableText(element: element, bundleId: bundleId, confidence: .high)
        }

        if selectedTextSettable, hasRange {
            return .editableText(element: element, bundleId: bundleId, confidence: .medium)
        }

        if editable == true {
            return .editableText(element: element, bundleId: bundleId, confidence: .medium)
        }

        return .nonEditable(bundleId: bundleId, role: role)
    }

    // MARK: - Level 1: AXSelectedText

    private func writeViaSelectedText(_ element: AXUIElement, text: String) -> Bool {
        let err = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if err == .success {
            print("[TypeFlow] Output: [L1-SelectedText] succeeded")
            return true
        }
        print("[TypeFlow] Output: [L1-SelectedText] failed (AXError=\(err.rawValue))")
        return false
    }

    // MARK: - Level 2: AXValue + AXSelectedTextRange splice

    private func writeViaValueSplice(_ element: AXUIElement, text: String) -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        ) == .success, let currentValue = valueRef as? String else {
            print("[TypeFlow] Output: [L2-ValueSplice] cannot read AXValue")
            return false
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeRef else {
            print("[TypeFlow] Output: [L2-ValueSplice] cannot read AXSelectedTextRange")
            return false
        }

        // Safe: kAXSelectedTextRangeAttribute returns AXValue on .success
        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else {
            print("[TypeFlow] Output: [L2-ValueSplice] cannot decode range")
            return false
        }

        let ns = currentValue as NSString
        let loc = min(cfRange.location, ns.length)
        let len = min(cfRange.length, ns.length - loc)
        let newValue = ns.replacingCharacters(
            in: NSRange(location: loc, length: len), with: text
        )

        let writeErr = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, newValue as CFTypeRef
        )
        if writeErr != .success {
            print("[TypeFlow] Output: [L2-ValueSplice] AXValue write failed (AXError=\(writeErr.rawValue))")
            return false
        }

        var newCursor = CFRange(location: loc + (text as NSString).length, length: 0)
        if let rangeVal = AXValueCreate(.cfRange, &newCursor) {
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, rangeVal
            )
        }

        print("[TypeFlow] Output: [L2-ValueSplice] succeeded (loc=\(loc), replaced=\(len))")
        return true
    }

    // MARK: - Level 3: Clipboard + Cmd+V with verification

    private func pasteWithVerification(
        _ text: String, element: AXUIElement, confidence: EditConfidence
    ) async -> Bool {
        let pb = NSPasteboard.general
        let valueBefore = axString(element, kAXValueAttribute)

        let backup = backupPasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChangeCount = pb.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            restorePasteboard(pb, from: backup)
            print("[TypeFlow] Output: [L3-Paste] CGEvent creation failed")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        try? await Task.sleep(for: .milliseconds(150))

        let valueAfter = axString(element, kAXValueAttribute)
        let verified: Bool

        if let before = valueBefore, let after = valueAfter {
            verified = (before != after)
            if verified {
                print("[TypeFlow] Output: [L3-Paste] verified — AXValue changed")
            } else {
                print("[TypeFlow] Output: [L3-Paste] FAILED — AXValue unchanged after Cmd+V")
            }
        } else if valueBefore == nil, valueAfter == nil {
            switch confidence {
            case .high:
                verified = true
                print("[TypeFlow] Output: [L3-Paste] unverifiable, high confidence → trust")
            case .medium:
                verified = false
                print("[TypeFlow] Output: [L3-Paste] unverifiable, medium confidence → distrust")
            }
        } else {
            verified = true
            print("[TypeFlow] Output: [L3-Paste] readability changed → assume success")
        }

        scheduleClipboardRestore(backup: backup, ourChangeCount: ourChangeCount)
        return verified
    }

    // MARK: - Blind Paste (last resort for unavailable focus)

    /// Sends Cmd+V without any AX element. Used when AX cannot see the focused app/element
    /// (e.g. Codex/Electron apps that block AX). Returns false only if CGEvent fails.
    private func blindPaste(_ text: String) async -> Bool {
        let pb = NSPasteboard.general
        let backup = backupPasteboard(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChangeCount = pb.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            restorePasteboard(pb, from: backup)
            print("[TypeFlow] Output: [blind-paste] CGEvent creation failed")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        scheduleClipboardRestore(backup: backup, ourChangeCount: ourChangeCount)
        return true
    }

    // MARK: - Clipboard Backup/Restore

    private func backupPasteboard(
        _ pb: NSPasteboard
    ) -> [[(NSPasteboard.PasteboardType, Data)]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    private func restorePasteboard(
        _ pb: NSPasteboard,
        from backup: [[(NSPasteboard.PasteboardType, Data)]]
    ) {
        pb.clearContents()
        guard !backup.isEmpty else { return }
        let items = backup.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    private func scheduleClipboardRestore(
        backup: [[(NSPasteboard.PasteboardType, Data)]],
        ourChangeCount: Int
    ) {
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if NSPasteboard.general.changeCount == ourChangeCount {
                restorePasteboard(NSPasteboard.general, from: backup)
                print("[TypeFlow] Output: clipboard restored")
            }
        }
    }

    // MARK: - Popup

    private func showPopup(_ text: String, hint: String? = nil) {
        print("[TypeFlow] Output: → popup enqueued (hint=\(hint ?? "none"))")
        let popup = resultPopup

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                popup.show(text: text, hint: hint)
                print("[TypeFlow] Output: popup show() returned")
            }
        }
    }

    // MARK: - AX Attribute Helpers

    private func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private func axBool(_ element: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        if let num = ref as? NSNumber { return num.boolValue }
        return nil
    }

    private func axExists(_ element: AXUIElement, _ attr: String) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success
    }

    private func axIsSettable(_ element: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attr as CFString, &settable)
        return err == .success && settable.boolValue
    }
}
