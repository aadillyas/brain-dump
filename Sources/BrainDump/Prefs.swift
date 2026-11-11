import BrainDumpCore
import BrainDumpLLM
import Foundation
import Security

enum Prefs {
    enum Key {
        static let notesPath = "notesPath"
        static let useCloud = "useCloud"
        static let localModelID = "localModelID"
        static let cloudModel = "cloudModel"
        static let remindersList = "remindersList"
        static let autoApproveReminders = "autoApproveReminders"
        static let autoApproveNotes = "autoApproveNotes"
        static let timerSeconds = "timerSeconds"
        static let remindersEnabled = "connectorRemindersEnabled"
        static let notesEnabled = "connectorNotesEnabled"
        static let calendarEnabled = "connectorCalendarEnabled"
        static let introSeen = "introSeen"
    }

    private static let d = UserDefaults.standard

    static var notesRoot: URL {
        let path = d.string(forKey: Key.notesPath) ?? ""
        return path.isEmpty ? NotesStore.defaultRoot : URL(fileURLWithPath: path)
    }

    static var useCloud: Bool { d.bool(forKey: Key.useCloud) }

    /// Stored in `localModelID` alongside the GGUF model's id.
    static let appleModelID = "apple"

    /// The model the app runs: Apple's or LFM3. Nothing stored, or a model the app no longer offers,
    /// means Apple's model when this Mac supports it and LFM3 otherwise.
    static var modelChoice: String {
        let stored = d.string(forKey: Key.localModelID) ?? ""
        if stored == appleModelID || stored == ModelCatalog.defaultModel.id { return stored }
        return Pipeline.appleAvailable ? appleModelID : ModelCatalog.defaultModel.id
    }

    static var useApple: Bool { modelChoice == appleModelID }

    /// The GGUF model to run, and the fallback when Apple's model is selected.
    static var localModel: LocalModel { ModelCatalog.defaultModel }

    static var cloudModel: String {
        let m = d.string(forKey: Key.cloudModel) ?? ""
        return m.isEmpty ? CloudLLM.defaultModel : m
    }

    static var remindersList: String? {
        let name = (d.object(forKey: Key.remindersList) as? String) ?? "Brain Dump"
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var autoApproved: Set<String> {
        var ids = Set<String>()
        if d.bool(forKey: Key.autoApproveReminders) { ids.insert("reminders") }
        if d.bool(forKey: Key.autoApproveNotes) { ids.insert("notes") }
        return ids
    }

    static let timerChoices: [(label: String, seconds: Int)] = [("30s", 30), ("1m", 60), ("5m", 300), ("10m", 600), ("Off", 0)]

    /// 0 means the timer is off.
    static var timerSeconds: Int {
        get { (d.object(forKey: Key.timerSeconds) as? Int) ?? 300 }
        set { d.set(newValue, forKey: Key.timerSeconds) }
    }

    static var remindersEnabled: Bool { (d.object(forKey: Key.remindersEnabled) as? Bool) ?? true }
    static var notesEnabled: Bool { (d.object(forKey: Key.notesEnabled) as? Bool) ?? true }
    static var calendarEnabled: Bool { (d.object(forKey: Key.calendarEnabled) as? Bool) ?? true }


    static var introSeen: Bool {
        get { d.bool(forKey: Key.introSeen) }
        set { d.set(newValue, forKey: Key.introSeen) }
    }
}

enum Keychain {
    private static let service = "app.braindump.BrainDump"
    static let apiKeyAccount = "anthropic-api-key"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String = apiKeyAccount) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String = apiKeyAccount) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
