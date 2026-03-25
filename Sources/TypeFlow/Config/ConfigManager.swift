import Foundation

@MainActor
final class ConfigManager {
    static let shared = ConfigManager()
    private let defaults = UserDefaults.standard

    var hotkeyKeyCode: UInt16 {
        get {
            let val = defaults.integer(forKey: "hotkeyKeyCode")
            return val == 0 ? 58 : UInt16(val) // 58 = Left Option
        }
        set { defaults.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    let minRecordingDuration: TimeInterval = 0.5
    let maxRecordingDuration: TimeInterval = 300 // 5 minutes

    var modelDirectory: String {
        get {
            defaults.string(forKey: "modelDirectory") ?? defaultModelDirectory
        }
        set { defaults.set(newValue, forKey: "modelDirectory") }
    }

    private var defaultModelDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TypeFlow/Models").path
    }

    private init() {}
}
