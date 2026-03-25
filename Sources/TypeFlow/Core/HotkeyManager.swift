import CoreGraphics
import Foundation

/// Monitors a modifier key (press-and-hold) via CGEvent tap.
///
/// Stage 2 limitation: only modifier keys (flagsChanged) are supported.
/// Regular key (keyDown/keyUp) hotkeys will be added in stage 6 with the settings UI.
@MainActor
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var comboDetected = false
    private var isPaused = false
    private let targetKeyCode: UInt16

    init(keyCode: UInt16 = 58) { // 58 = Left Option
        self.targetKeyCode = keyCode
    }

    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyEventCallback,
            userInfo: selfPtr
        ) else {
            print("[TypeFlow] Failed to create event tap — accessibility permission required")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[TypeFlow] Hotkey monitoring started (keycode: \(targetKeyCode))")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
        comboDetected = false
    }

    /// Called from the C callback. CGEvent tap callbacks are not guaranteed
    /// to arrive on the main thread, so forward state handling onto MainActor.
    nonisolated fileprivate func handleEventFromCallback(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        Task { @MainActor in
            self.handleEvent(type: type, keyCode: keyCode, flags: flags)
        }
    }

    private func handleEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:
            if isPressed {
                comboDetected = true
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        default:
            break
        }
    }

    func pause() {
        isPaused = true
        if isPressed {
            isPressed = false
            comboDetected = false
            onCancel?()
        }
    }

    func resume() {
        isPaused = false
    }

    private var targetModifierFlag: CGEventFlags {
        switch targetKeyCode {
        case 58, 61: .maskAlternate
        case 59, 62: .maskControl
        case 56, 60: .maskShift
        case 55, 54: .maskCommand
        case 57: .maskAlphaShift
        case 63: .maskSecondaryFn
        default: .maskAlternate
        }
    }

    private func handleFlagsChanged(keyCode: UInt16, flags: CGEventFlags) {
        guard !isPaused else { return }
        guard keyCode == targetKeyCode else { return }

        let modifierPressed = flags.contains(targetModifierFlag)

        if modifierPressed && !isPressed {
            isPressed = true
            comboDetected = false
            onPress?()
        } else if !modifierPressed && isPressed {
            isPressed = false
            if comboDetected {
                comboDetected = false
                onCancel?()
            } else {
                onRelease?()
            }
        }
    }

    deinit {
        // stop() is @MainActor, but deinit is nonisolated.
        // The event tap will be invalidated when the CFMachPort is deallocated.
    }
}

// C function pointer for CGEvent tap — forwards handling onto MainActor.
private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    manager.handleEventFromCallback(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
