import Foundation
import Combine
import ServiceManagement

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T

    init(_ key: String, defaultValue: T) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: T {
        get {
            return UserDefaults.standard.object(forKey: key) as? T ?? defaultValue
        }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }
}

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private init() {}

    @UserDefault(SettingsKeys.enabled, defaultValue: true)
    var enabled: Bool {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.ollamaURL, defaultValue: "http://localhost:11434")
    var ollamaURL: String {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.model, defaultValue: "qwen2.5:1.5b")
    var model: String {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.debounceMs, defaultValue: 200)
    var debounceMs: Int {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.completionLength, defaultValue: "medium")
    var completionLength: String {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.contextChars, defaultValue: 2000)
    var contextChars: Int {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.clipboardAwareness, defaultValue: true)
    var clipboardAwareness: Bool {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.screenAwareMode, defaultValue: true)
    var screenAwareMode: Bool {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.personalizationLevel, defaultValue: 4)
    var personalizationLevel: Int {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.customInstructions, defaultValue: "")
    var customInstructions: String {
        willSet { objectWillChange.send() }
    }

    var perAppInstructions: [String: String] {
        get {
            return UserDefaults.standard.dictionary(forKey: SettingsKeys.perAppInstructions) as? [String: String] ?? [:]
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: SettingsKeys.perAppInstructions)
        }
    }

    @UserDefault(SettingsKeys.enableEmoji, defaultValue: true)
    var enableEmoji: Bool {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.enableTypoDetection, defaultValue: true)
    var enableTypoDetection: Bool {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.enableMidLine, defaultValue: true)
    var enableMidLine: Bool {
        willSet { objectWillChange.send() }
    }

    @UserDefault(SettingsKeys.debugMode, defaultValue: false)
    var debugMode: Bool {
        willSet { objectWillChange.send() }
    }

    var blockedBundleIDs: Set<String> {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: SettingsKeys.blockedBundleIDs) ?? []
            return Set(stored).union(AppSettings.defaultBlockedBundleIDs)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(Array(newValue), forKey: SettingsKeys.blockedBundleIDs)
        }
    }

    static let defaultBlockedBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
        "com.1password.1password",
        "com.agilebits.onepassword",
        "com.bitwarden.desktop",
        "com.apple.systempreferences",
    ]

    var numPredictTokens: Int {
        switch completionLength {
        case "short": return 15
        case "long":  return 60
        default:      return 30
        }
    }

    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    DebugLogger.log("Launch at login toggle failed: \(error)")
                }
            }
        }
    }
}
