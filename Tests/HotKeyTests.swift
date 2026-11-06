import AppKit
import Carbon
import Darwin

/// Exercises Carbon registration using the production service. It never sends
/// input events, creates windows, or constructs a clipboard monitor/store.
@main
@MainActor
struct HotKeyTests {
    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() {
        let result: Int32
        do {
            result = try run()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            result = 1
        }
        // run() has returned/unwound, so all deferred unregistrations run first.
        exit(result)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(description: message) }
    }

    private static func run() throws -> Int32 {
        let modifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        let candidates: [(key: UInt32, label: String)] = [
            (UInt32(kVK_F18), "⌃⌥⇧⌘F18"),
            (UInt32(kVK_F19), "⌃⌥⇧⌘F19")
        ]
        var reservations: [(key: UInt32, label: String, owner: GlobalHotKey)] = []
        let probe = GlobalHotKey()
        defer {
            probe.unregister()
            for reservation in reservations { reservation.owner.unregister() }
        }

        // Find/reserve candidates before making assertions. Existing applications
        // or a restricted desktop session may legitimately make them unavailable.
        for candidate in candidates {
            let owner = GlobalHotKey()
            if owner.register(keyCode: candidate.key, modifiers: modifiers, action: {}) {
                reservations.append((candidate.key, candidate.label, owner))
            } else {
                owner.unregister()
                print("UNAVAILABLE: \(candidate.label)")
            }
        }
        guard reservations.count == 2 else {
            print("SKIP: Two unused F18/F19 candidates were not available in this session. No registration assertions ran. Exit code 77.")
            return 77
        }

        let original = reservations[0]
        let occupied = reservations[1]
        print("Reserved candidates: \(original.label), \(occupied.label)")

        try expect(original.owner.register(keyCode: original.key, modifiers: modifiers, action: {}),
                   "Registering the same shortcut on its existing owner must succeed.")
        print("PASS: Re-registering the same shortcut on the same instance succeeds.")

        try expect(!probe.register(keyCode: original.key, modifiers: modifiers, action: {}),
                   "A second instance must not acquire an occupied shortcut.")
        print("PASS: Another instance cannot register the reserved shortcut.")

        try expect(!original.owner.register(keyCode: occupied.key, modifiers: modifiers, action: {}),
                   "Changing to a reserved shortcut must fail.")
        try expect(!probe.register(keyCode: original.key, modifiers: modifiers, action: {}),
                   "A failed shortcut change must retain the original reservation.")
        print("PASS: A failed shortcut change preserves the original shortcut.")

        original.owner.unregister()
        try expect(probe.register(keyCode: original.key, modifiers: modifiers, action: {}),
                   "Unregistering must release the shortcut for another instance.")
        probe.unregister()
        try expect(original.owner.register(keyCode: original.key, modifiers: modifiers, action: {}),
                   "A service must be able to register again after unregistering.")
        print("PASS: Unregistering releases the shortcut and permits registration again.")

        original.owner.unregister()
        var temporaryOwner: GlobalHotKey? = GlobalHotKey()
        try expect(temporaryOwner!.register(keyCode: original.key, modifiers: modifiers, action: {}),
                   "The released shortcut must be available to a temporary owner.")
        temporaryOwner = nil
        try expect(probe.register(keyCode: original.key, modifiers: modifiers, action: {}),
                   "Destroying a service must release its Carbon reservation.")
        print("PASS: Deinitialization releases the shortcut.")

        print("Passed 5 hot-key registration tests. No keystrokes were sent; clipboard and screen were not accessed.")
        return 0
    }
}
