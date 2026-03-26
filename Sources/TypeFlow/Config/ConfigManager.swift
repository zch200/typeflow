import Foundation
import Security

@MainActor
final class ConfigManager {
    static let shared = ConfigManager()
    private let defaults = UserDefaults.standard

    // MARK: - Hotkey

    var hotkeyKeyCode: UInt16 {
        get {
            let val = defaults.integer(forKey: "hotkeyKeyCode")
            return val == 0 ? 58 : UInt16(val) // 58 = Left Option
        }
        set { defaults.set(Int(newValue), forKey: "hotkeyKeyCode") }
    }

    // MARK: - Recording

    let minRecordingDuration: TimeInterval = 0.5

    var maxRecordingDuration: TimeInterval {
        switch speechEngineType {
        case .whisperLocal: return 300   // 5 minutes
        case .qwenCloud:    return 180   // 3 minutes (PCM16 WAV base64 ≈ 7.7 MB, 留足 10 MB 余量)
        }
    }

    // MARK: - Speech Engine

    var speechEngineType: SpeechEngineType {
        get {
            let raw = defaults.integer(forKey: "speechEngineType")
            return SpeechEngineType(rawValue: raw) ?? .whisperLocal
        }
        set { defaults.set(newValue.rawValue, forKey: "speechEngineType") }
    }

    var cloudSpeechModel: String {
        get { defaults.string(forKey: "cloudSpeechModel") ?? "qwen3-asr-flash" }
        set { defaults.set(newValue, forKey: "cloudSpeechModel") }
    }

    var cloudSpeechEndpoint: String {
        get { defaults.string(forKey: "cloudSpeechEndpoint") ?? "https://dashscope.aliyuncs.com/compatible-mode" }
        set { defaults.set(newValue, forKey: "cloudSpeechEndpoint") }
    }

    var cloudSpeechApiKey: String? {
        get { KeychainHelper.load(service: "com.typeflow.app", account: "speech-api-key") }
        set {
            if let newValue {
                KeychainHelper.save(service: "com.typeflow.app", account: "speech-api-key", data: newValue)
            } else {
                KeychainHelper.delete(service: "com.typeflow.app", account: "speech-api-key")
            }
        }
    }

    // MARK: - Whisper Model

    /// Full path to the whisper model file.
    /// Migration: reads legacy "modelDirectory" key so existing users keep their custom path.
    var modelPath: String {
        get {
            if let path = defaults.string(forKey: "modelPath"), !path.isEmpty {
                return path
            }
            // Legacy migration: honour old "modelDirectory" key if set
            let dir = defaults.string(forKey: "modelDirectory") ?? defaultModelDirectory
            return (dir as NSString).appendingPathComponent("ggml-large-v3-turbo.bin")
        }
        set { defaults.set(newValue, forKey: "modelPath") }
    }

    private var defaultModelDirectory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TypeFlow/Models").path
    }

    // MARK: - LLM

    var llmEndpoint: String {
        get { defaults.string(forKey: "llmEndpoint") ?? "https://dashscope.aliyuncs.com/compatible-mode" }
        set { defaults.set(newValue, forKey: "llmEndpoint") }
    }

    var llmModel: String {
        get { defaults.string(forKey: "llmModel") ?? "qwen-turbo" }
        set { defaults.set(newValue, forKey: "llmModel") }
    }

    var llmSystemPrompt: String {
        get { defaults.string(forKey: "llmSystemPrompt") ?? Self.defaultSystemPrompt }
        set { defaults.set(newValue, forKey: "llmSystemPrompt") }
    }

    var llmApiKey: String? {
        get { KeychainHelper.load(service: "com.typeflow.app", account: "llm-api-key") }
        set {
            if let newValue {
                KeychainHelper.save(service: "com.typeflow.app", account: "llm-api-key", data: newValue)
            } else {
                KeychainHelper.delete(service: "com.typeflow.app", account: "llm-api-key")
            }
        }
    }

    static let defaultSystemPrompt = """
        你是一个语音转文字的润色助手。请对以下语音识别文本进行润色：
        1. 修正明显的语音识别错误和错别字
        2. 去除口语化的语气词（如"嗯"、"那个"、"就是说"等）
        3. 使文本更加通顺自然，保持原意不变
        4. 不要添加原文没有的信息
        5. 必须使用简体中文输出，将繁体字转换为简体字
        6. 直接输出润色后的文本，不要有任何额外说明
        """

    // MARK: - Unavailable Focus Strategy

    var unavailableFocusStrategy: UnavailableFocusStrategy {
        get {
            let raw = defaults.integer(forKey: "unavailableFocusStrategy")
            return UnavailableFocusStrategy(rawValue: raw) ?? .blindPasteThenPopup
        }
        set { defaults.set(newValue.rawValue, forKey: "unavailableFocusStrategy") }
    }

    /// Resolve strategy for a specific app. Per-app overrides take precedence over global default.
    func strategyForApp(_ bundleId: String?) -> UnavailableFocusStrategy {
        guard let bundleId else { return unavailableFocusStrategy }
        if let override = Self.appStrategyOverrides[bundleId] { return override }
        return unavailableFocusStrategy
    }

    private static let appStrategyOverrides: [String: UnavailableFocusStrategy] = [
        // Non-editing apps → popup only
        "com.apple.finder": .popupOnly,
        "com.apple.Preview": .popupOnly,
        "com.apple.SystemPreferences": .popupOnly,
        "com.apple.systempreferences": .popupOnly,
        // Electron/AX-opaque apps where blind paste works reliably in practice.
        // Avoid popup here because AppKit window presentation can stall the main actor.
        "com.openai.codex": .blindPasteOnly,
        "com.tencent.xinWeChat": .blindPasteOnly,
        "com.tencent.WeWorkMac": .blindPasteThenPopup,
    ]

    // MARK: - Indicator Position

    var indicatorPosition: (x: Double, y: Double)? {
        get {
            guard defaults.object(forKey: "indicatorX") != nil else { return nil }
            return (defaults.double(forKey: "indicatorX"), defaults.double(forKey: "indicatorY"))
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: "indicatorX")
                defaults.set(p.y, forKey: "indicatorY")
            } else {
                defaults.removeObject(forKey: "indicatorX")
                defaults.removeObject(forKey: "indicatorY")
            }
        }
    }

    // MARK: - Display Helpers

    static func hotkeyDisplayName(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 58: "⌥ Left Option"
        case 61: "⌥ Right Option"
        case 59: "⌃ Left Control"
        case 62: "⌃ Right Control"
        case 56: "⇧ Left Shift"
        case 60: "⇧ Right Shift"
        case 55: "⌘ Left Command"
        case 54: "⌘ Right Command"
        case 57: "⇪ Caps Lock"
        case 63: "fn Function"
        default: "Key \(keyCode)"
        }
    }

    private init() {}
}

// MARK: - UnavailableFocusStrategy

enum UnavailableFocusStrategy: Int, CustomStringConvertible {
    case blindPasteOnly = 0
    case blindPasteThenPopup = 1
    case popupOnly = 2

    var description: String {
        switch self {
        case .blindPasteOnly: "blindPasteOnly"
        case .blindPasteThenPopup: "blindPasteThenPopup"
        case .popupOnly: "popupOnly"
        }
    }
}

// MARK: - Keychain Helper

private enum KeychainHelper {
    static func save(service: String, account: String, data: String) {
        guard let bytes = data.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Remove existing item first
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = bytes
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            print("[TypeFlow] Keychain save failed: \(status)")
        }
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
