import Foundation
import Combine
import Carbon

@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var retentionHours: Double { didSet { save() } }
    @Published var maxItems: Int { didSet { save() } }
    @Published var maxImageMB: Double { didSet { save() } }
    @Published var maxImageStorageMB: Double { didSet { save() } }
    @Published var showsMenuBar: Bool { didSet { save() } }
    @Published var paused: Bool { didSet { save() } }
    @Published var excludedBundleIDs: [String] { didSet { save() } }
    @Published var hotKeyCode: UInt32 { didSet { save() } }
    @Published var hotKeyModifiers: UInt32 { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        retentionHours = defaults.object(forKey: "retentionHours") as? Double ?? 48
        maxItems = defaults.object(forKey: "maxItems") as? Int ?? 100
        maxImageMB = defaults.object(forKey: "maxImageMB") as? Double ?? 20
        maxImageStorageMB = defaults.object(forKey: "maxImageStorageMB") as? Double ?? 256
        showsMenuBar = defaults.object(forKey: "showsMenuBar") as? Bool ?? true
        paused = defaults.bool(forKey: "paused")
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        hotKeyCode = UInt32(defaults.object(forKey: "hotKeyCode") as? Int ?? 9)
        hotKeyModifiers = UInt32(defaults.object(forKey: "hotKeyModifiers") as? Int ?? Int(cmdKey | shiftKey))
    }

    private func save() {
        defaults.set(retentionHours, forKey: "retentionHours")
        defaults.set(maxItems, forKey: "maxItems")
        defaults.set(maxImageMB, forKey: "maxImageMB")
        defaults.set(maxImageStorageMB, forKey: "maxImageStorageMB")
        defaults.set(showsMenuBar, forKey: "showsMenuBar")
        defaults.set(paused, forKey: "paused")
        defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs")
        defaults.set(Int(hotKeyCode), forKey: "hotKeyCode")
        defaults.set(Int(hotKeyModifiers), forKey: "hotKeyModifiers")
    }

    var shortcutKeys: [String] {
        var keys: [String] = []
        if hotKeyModifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if hotKeyModifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if hotKeyModifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if hotKeyModifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        keys.append(Self.keyLabels[hotKeyCode, default: "?"])
        return keys
    }

    var shortcutLabel: String { shortcutKeys.joined(separator: "\u{2009}") }

    static let keyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Space"
    ]
}
