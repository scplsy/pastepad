import Foundation
import Darwin

@main
struct PresentationOrderTests {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ actual: [String], _ expected: [String], _ message: String) throws {
        guard actual == expected else {
            throw Failure(description: "\(message) Expected \(expected), received \(actual).")
        }
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let merge: ([String], [String]) -> [String] = ClipboardPresentationOrder.merging
        let initial = ["newest", "middle", "oldest"]

        try expect(merge([], initial), initial, "A fresh presentation must use stored recency.")
        try expect(merge(initial, ["oldest", "newest", "middle"]), initial,
                   "Copying an older row must keep its current position.")
        try expect(merge(initial, ["middle", "oldest", "newest"]), initial,
                   "Several copies must not change the presentation order.")
        print("PASS: Opening uses recency, while repeated copies preserve row positions.")

        let withCaptures = merge(initial, ["capture-2", "oldest", "capture-1", "newest", "middle"])
        try expect(withCaptures, ["capture-2", "capture-1", "newest", "middle", "oldest"],
                   "New captures must arrive on top in recency order despite copied existing rows.")
        try expect(merge(withCaptures, ["manual", "middle", "capture-2", "oldest", "capture-1", "newest"]),
                   ["manual", "capture-2", "capture-1", "newest", "middle", "oldest"],
                   "A manual entry must appear above existing rows.")
        print("PASS: External captures and manual entries appear above existing rows.")

        let afterCleanup = merge(withCaptures, ["oldest", "capture-1", "newest"])
        try expect(afterCleanup, ["capture-1", "newest", "oldest"],
                   "Deleted or expired rows must disappear without reordering survivors.")
        try expect(merge(afterCleanup, []), [], "Clearing the history must remove all presentation IDs.")
        try expect(merge(afterCleanup, ["replacement", "oldest"]), ["replacement", "oldest"],
                   "A combined capture and cleanup must prepend additions and discard deleted rows.")
        print("PASS: Cleanup, deletion, and combined insertion preserve only current rows.")

        let updatedStore = ["oldest", "newest", "middle"]
        let groupA: Set<String> = ["middle", "oldest"]
        let stable = merge(initial, updatedStore)
        try expect(stable.filter { groupA.contains($0) }, ["middle", "oldest"],
                   "Group and search filtering must inherit the same global presentation order.")
        try expect(merge(stable, updatedStore), initial,
                   "Switching back to all items must not apply deferred recency changes.")
        try expect(merge([], updatedStore), updatedStore,
                   "Reopening must apply the copied row's persisted recency.")
        print("PASS: Filtering preserves order, and reopening applies deferred recency.")
        print("All 4 presentation order checks passed.")
    }
}
