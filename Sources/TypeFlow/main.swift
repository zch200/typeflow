import AppKit

// Ensure print() output is line-buffered even when stdout is redirected
setvbuf(stdout, nil, _IOLBF, 0)

// Single instance guard — prevent duplicate menu bar icons
let myPID = ProcessInfo.processInfo.processIdentifier
let bundleId = Bundle.main.bundleIdentifier ?? "com.typeflow.app"
let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    .filter { $0.processIdentifier != myPID }

if !otherInstances.isEmpty {
    print("[TypeFlow] Another instance already running (bundle: \(bundleId), PIDs: \(otherInstances.map(\.processIdentifier))). Exiting.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
