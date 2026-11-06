import AppKit
import Foundation

@main
@MainActor
struct StoreTests {
    static var passed = 0

    static func main() throws {
        try run("text deduplication preserves metadata and survives restart", testTextDeduplication)
        try run("manual templates preserve text, groups, notes, and independent identities", testManualTemplates)
        try run("manual creation rejects invalid input without changing history", testManualValidation)
        try run("manual creation obeys cleanup limits and locked exemptions", testManualLimits)
        try run("manual creation only returns successfully persisted identities", testManualWriteFailure)
        try run("history reuse refreshes retention without changing source or metadata", testReuse)
        try run("groups move items without losing content or locks", testGroups)
        try run("expiration, count limits, and unlock reset", testCleanup)
        try run("PNG persistence, deduplication, and file reclamation", testImages)
        try run("capture and unlocked image storage limits", testImageLimits)
        try run("image storage reduction evicts strictly oldest first", testImageEvictionOrder)
        try run("corrupt and newer history are never overwritten", testLoadFailure)
        try run("failed manifest writes preserve state and remove new images", testWriteFailure)
        print("Passed \(passed) storage tests.")
    }

    static func run(_ name: String, _ test: () throws -> Void) throws {
        try test()
        passed += 1
        print("PASS: \(name)")
    }

    private struct TestFailure: Error {
        let message: String
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(message: message) }
    }

    static func sameItems(_ lhs: [ClipboardItem], _ rhs: [ClipboardItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            guard abs(left.lastCopiedAt.timeIntervalSince(right.lastCopiedAt)) < 0.001 else { return false }
            var normalized = right
            normalized.lastCopiedAt = left.lastCopiedAt
            return left == normalized
        }
    }

    static func withDirectory(_ body: (URL, AppSettings) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapasteStoreTests-" + UUID().uuidString, isDirectory: true)
        let suite = "TapasteStoreTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        try body(directory, AppSettings(defaults: defaults))
    }

    static func testTextDeduplication() throws {
        try withDirectory { directory, settings in
            let store = ClipboardStore(settings: settings, directory: directory)
            let text = "https://example.com/路径\n  original spacing  "
            store.addText(text, sourceApp: "Safari", sourceBundleID: "com.apple.Safari")
            let id = store.items[0].id
            store.addGroup(name: "Work")
            let groupID = store.groups[0].id
            store.move(id, to: groupID)
            store.updateNote(id, note: "Useful reference")
            store.toggleLock(id)
            let previousDate = store.items[0].lastCopiedAt
            store.addText(text, sourceApp: "Notes", sourceBundleID: "com.apple.Notes")
            try expect(store.items.count == 1, "Repeated text created a duplicate")
            let item = store.items[0]
            try expect(item.id == id && item.text == text, "Repeated text changed its identity or content")
            try expect(item.note == "Useful reference" && item.groupID == groupID && item.isLocked,
                   "Repeated text lost metadata")
            try expect(item.lastCopiedAt >= previousDate && item.sourceApp == "Notes", "Recapture did not update source and time")
            let reopened = ClipboardStore(settings: settings, directory: directory)
            try expect(sameItems(reopened.items, store.items) && reopened.groups == store.groups, "Restart changed saved data")
            reopened.addText(text, sourceApp: "Finder", sourceBundleID: nil)
            try expect(reopened.items.count == 1 && reopened.items[0].id == id, "Deduplication failed after restart")
        }
    }

    static func testGroups() throws {
        try withDirectory { directory, settings in
            let store = ClipboardStore(settings: settings, directory: directory)
            store.addText("one", sourceApp: "Test", sourceBundleID: nil)
            let firstID = store.items[0].id
            store.addText("two", sourceApp: "Test", sourceBundleID: nil)
            let secondID = store.items[0].id
            store.toggleLock(firstID)
            store.addGroup(name: "  Work  ")
            let groupID = store.groups[0].id
            try expect(store.groups[0].name == "Work", "Group name was not normalized")
            store.addGroup(name: "work")
            try expect(store.groups.count == 1 && store.issue != nil, "Duplicate group was accepted")
            store.renameGroup(groupID, name: "References")
            store.move(firstID, to: groupID)
            store.move(secondID, to: groupID)
            store.updateNote(firstID, note: "keep")
            store.deleteGroup(groupID)
            try expect(store.groups.isEmpty && store.items.count == 2, "Deleting a group deleted its contents")
            try expect(store.items.allSatisfy { $0.groupID == nil }, "Deleting a group left dangling memberships")
            let locked = store.items.first { $0.id == firstID }!
            try expect(locked.isLocked && locked.note == "keep", "Deleting a group changed other metadata")
            store.clearUnlocked()
            try expect(store.items.map(\.id) == [firstID], "Clear history did not preserve locked items")
            store.delete(firstID)
            try expect(store.items.isEmpty, "Locked item could not be manually deleted")
        }
    }

    static func testManualTemplates() throws {
        try withDirectory { directory, settings in
            let store = ClipboardStore(settings: settings, directory: directory)
            let text = "  Dear team,\n\nHere is the update.\n  "
            store.addText(text, sourceApp: "Mail", sourceBundleID: "com.apple.mail")
            let capturedID = store.items[0].id
            store.updateNote(capturedID, note: "Original copied message")
            store.addGroup(name: "Work")
            store.addGroup(name: "Personal")
            let work = store.groups[0].id
            let personal = store.groups[1].id
            let workID = store.createText(text, note: "Work template\nSecond note line", groupID: work)
            let personalID = store.createText(text, note: "Personal template", groupID: personal, isLocked: true)
            try expect(workID != nil && personalID != nil && workID != personalID, "Manual duplicate identities were merged")
            try expect(store.items.count == 3, "Manual templates replaced existing clipboard history")
            let expected = store.items
            let reopened = ClipboardStore(settings: settings, directory: directory)
            try expect(sameItems(reopened.items, expected) && reopened.groups == store.groups,
                       "Manual template content or metadata changed after restart")
            let workItem = reopened.items.first { $0.id == workID }!
            let personalItem = reopened.items.first { $0.id == personalID }!
            try expect(workItem.text == text && workItem.groupID == work && workItem.note == "Work template\nSecond note line",
                       "Manual creation changed line breaks or assigned metadata incorrectly")
            try expect(workItem.sourceApp == L("Manual entry", "手动创建") && !workItem.isLocked,
                       "Manual entry source or default lock state was incorrect")
            try expect(personalItem.groupID == personal && personalItem.note == "Personal template" && personalItem.isLocked,
                       "Independent template group, note, or lock state was lost")
            reopened.addText(text, sourceApp: "Notes", sourceBundleID: "com.apple.Notes")
            try expect(reopened.items.count == 3 && Set(reopened.items.map(\.id)) == Set(expected.map(\.id)),
                       "Clipboard recapture merged independent manual templates")
            for oldItem in expected {
                let newItem = reopened.items.first { $0.id == oldItem.id }!
                try expect(newItem.text == oldItem.text && newItem.note == oldItem.note
                           && newItem.groupID == oldItem.groupID && newItem.isLocked == oldItem.isLocked,
                           "Clipboard recapture overwrote template metadata")
            }
        }
    }

    static func testManualValidation() throws {
        try withDirectory { directory, settings in
            let store = ClipboardStore(settings: settings, directory: directory)
            store.addText("existing", sourceApp: "Test", sourceBundleID: nil)
            let beforeItems = store.items
            let manifest = directory.appendingPathComponent("history.json")
            let beforeData = try Data(contentsOf: manifest)
            try expect(store.createText(" \t\n\r\u{3000}", note: "empty", groupID: nil) == nil && store.issue != nil,
                       "Whitespace-only manual text was accepted")
            try expect(store.createText("valid", note: "bad group", groupID: UUID()) == nil && store.issue != nil,
                       "Manual item accepted a nonexistent group")
            try expect(store.items == beforeItems, "Invalid manual input changed the published history")
            try expect(try Data(contentsOf: manifest) == beforeData, "Invalid manual input rewrote the saved history")

            let corrupt = Data("{unreadable".utf8)
            try corrupt.write(to: manifest, options: .atomic)
            let unavailable = ClipboardStore(settings: settings, directory: directory)
            unavailable.issue = nil
            try expect(unavailable.createText("cannot save", note: "", groupID: nil) == nil && unavailable.issue != nil,
                       "Manual creation did not explain a disabled store")
            try expect(try Data(contentsOf: manifest) == corrupt, "Manual creation overwrote unreadable history")
        }
    }

    static func testManualLimits() throws {
        try withDirectory { directory, settings in
            settings.maxItems = 1
            let store = ClipboardStore(settings: settings, directory: directory)
            let firstID = store.createText("old unlocked", note: "", groupID: nil)
            let lockedID = store.createText("locked", note: "permanent", groupID: nil, isLocked: true)
            let latestID = store.createText("latest unlocked", note: "", groupID: nil)
            try expect(firstID != nil && lockedID != nil && latestID != nil, "Valid limited manual creation failed")
            try expect(Set(store.items.map(\.id)) == Set([lockedID!, latestID!]),
                       "Manual creation failed to evict the oldest unlocked entry or counted a locked item")
            settings.maxItems = 0
            let beforeItems = store.items
            let manifest = directory.appendingPathComponent("history.json")
            let beforeData = try Data(contentsOf: manifest)
            try expect(store.createText("cannot fit", note: "", groupID: nil) == nil && store.issue != nil,
                       "Manual creation returned an identity that was removed by cleanup")
            try expect(store.items == beforeItems, "Failed capacity validation changed existing entries")
            try expect(try Data(contentsOf: manifest) == beforeData, "Failed capacity validation rewrote history")
            let exemptID = store.createText("locked over limit", note: "", groupID: nil, isLocked: true)
            try expect(exemptID != nil && store.items.contains { $0.id == exemptID }, "Locked creation did not bypass unlocked capacity")
            settings.retentionHours = 0
            try expect(store.createText("expires immediately", note: "", groupID: nil) == nil && store.issue != nil,
                       "Manual creation succeeded despite immediate expiration")
            let locked = store.items.filter(\.isLocked)
            store.cleanup(now: Date().addingTimeInterval(365 * 24 * 3_600))
            try expect(store.items == locked, "Cleanup removed locked manual templates")
        }
    }

    static func testManualWriteFailure() throws {
        try withDirectory { directory, settings in
            let store = ClipboardStore(settings: settings, directory: directory)
            store.addText("original", sourceApp: "Test", sourceBundleID: nil)
            let originalItems = store.items
            let manifest = directory.appendingPathComponent("history.json")
            let backup = directory.appendingPathComponent("history.before-manual-failure.json")
            try FileManager.default.moveItem(at: manifest, to: backup)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            try expect(store.createText("unsaved", note: "note", groupID: nil) == nil && store.issue != nil,
                       "Manual creation returned an identity before a successful save")
            try expect(store.items == originalItems, "Failed manual save changed published entries")
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.moveItem(at: backup, to: manifest)
            let restored = ClipboardStore(settings: settings, directory: directory)
            try expect(sameItems(restored.items, originalItems), "Failed manual save changed existing disk data")
            let recoveredID = store.createText("saved", note: "recovered", groupID: nil)
            let reopened = ClipboardStore(settings: settings, directory: directory)
            try expect(recoveredID != nil && reopened.items.contains { $0.id == recoveredID && $0.note == "recovered" },
                       "Successful manual identity was not persisted")
        }
    }

    static func testReuse() throws {
        try withDirectory { directory, settings in
            let original = ClipboardStore(settings: settings, directory: directory)
            original.addText("reuse", sourceApp: "Original app", sourceBundleID: "dev.test.source")
            let id = original.items[0].id
            original.addGroup(name: "Reference")
            let groupID = original.groups[0].id
            original.move(id, to: groupID)
            original.updateNote(id, note: "preserve this note")
            let oldDate = Date().addingTimeInterval(-47 * 3_600)
            let manifest = directory.appendingPathComponent("history.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            var items = json["items"] as! [[String: Any]]
            items[0]["lastCopiedAt"] = oldDate.timeIntervalSince1970 * 1_000
            json["items"] = items
            try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
            let store = ClipboardStore(settings: settings, directory: directory)
            store.recordReuse(id)
            let reused = store.items[0]
            try expect(reused.lastCopiedAt.timeIntervalSince(oldDate) > 46 * 3_600, "Reuse did not update its timestamp")
            try expect(reused.sourceApp == "Original app" && reused.sourceBundleID == "dev.test.source",
                   "Reuse replaced the original source")
            try expect(reused.id == id && reused.note == "preserve this note" && reused.groupID == groupID,
                   "Reuse changed identity or metadata")
            store.cleanup(now: oldDate.addingTimeInterval(48 * 3_600 + 1))
            try expect(store.items.count == 1, "Reuse did not reset the retention period")
        }
    }

    static func testCleanup() throws {
        try withDirectory { directory, settings in
            settings.maxItems = 2
            let store = ClipboardStore(settings: settings, directory: directory)
            store.addText("one", sourceApp: "Test", sourceBundleID: nil)
            let lockedID = store.items[0].id
            store.toggleLock(lockedID)
            store.addText("two", sourceApp: "Test", sourceBundleID: nil)
            store.addText("three", sourceApp: "Test", sourceBundleID: nil)
            store.addText("four", sourceApp: "Test", sourceBundleID: nil)
            try expect(Set(store.items.map(\.text)) == ["one", "three", "four"], "Count limit counted a locked item or kept the wrong items")
            let latest = store.items.map(\.lastCopiedAt).max()!
            store.cleanup(now: latest.addingTimeInterval(48 * 3_600 + 1))
            try expect(store.items.map(\.id) == [lockedID], "Expiration did not preserve only the locked item")
            store.addText("recent", sourceApp: "Test", sourceBundleID: nil)
            settings.maxItems = 1
            store.toggleLock(lockedID)
            try expect(store.items.map(\.id) == [lockedID], "Unlocked item did not become the newest entry")
            let unlocked = store.items[0]
            try expect(!unlocked.isLocked && unlocked.lastCopiedAt >= latest, "Unlock did not reset the retention clock")
            store.cleanup(now: unlocked.lastCopiedAt.addingTimeInterval(48 * 3_600 - 1))
            try expect(store.items.count == 1, "Unlocked item expired too soon")
            store.cleanup(now: unlocked.lastCopiedAt.addingTimeInterval(48 * 3_600))
            try expect(store.items.isEmpty, "Unlocked item did not expire at the configured boundary")
        }
    }

    static func png(_ red: UInt8, _ green: UInt8, _ blue: UInt8, size: Int = 4) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32
        )!
        let pixels = bitmap.bitmapData!
        for x in 0..<size {
            for y in 0..<size {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
                pixels[offset + 3] = 255
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    static func imageFiles(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Images"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
    }

    static func testImages() throws {
        try withDirectory { directory, settings in
            let data = png(20, 80, 220)
            let store = ClipboardStore(settings: settings, directory: directory)
            store.addImage(data, sourceApp: "Preview", sourceBundleID: "com.apple.Preview")
            try expect(store.items.count == 1 && store.issue == nil, "Valid PNG was not accepted")
            let id = store.items[0].id
            let imageURL = store.imageURL(for: store.items[0])!
            try expect(try Data(contentsOf: imageURL) == data, "PNG data was transformed")
            try expect(store.image(for: store.items[0]) != nil, "Stored image cannot be previewed")
            store.updateNote(id, note: "blue")
            store.toggleLock(id)
            store.addImage(data, sourceApp: "Test", sourceBundleID: nil)
            try expect(store.items.count == 1 && store.items[0].id == id && store.items[0].isLocked,
                   "PNG recapture lost identity or lock")
            try expect(try imageFiles(directory).count == 1, "PNG recapture wrote another file")
            let reopened = ClipboardStore(settings: settings, directory: directory)
            reopened.addImage(data, sourceApp: "Test", sourceBundleID: nil)
            try expect(reopened.items.count == 1 && reopened.items[0].note == "blue", "PNG restart deduplication lost metadata")
            let orphan = directory.appendingPathComponent("Images/" + UUID().uuidString + ".png")
            try data.write(to: orphan)
            _ = ClipboardStore(settings: settings, directory: directory)
            try expect(!FileManager.default.fileExists(atPath: orphan.path), "Unreferenced image was not reclaimed on load")
            reopened.delete(id)
            try expect(!FileManager.default.fileExists(atPath: imageURL.path), "Deleted image file was not reclaimed")
        }
    }

    static func testImageLimits() throws {
        try withDirectory { directory, settings in
            let first = png(255, 0, 0)
            let second = png(0, 255, 0)
            let store = ClipboardStore(settings: settings, directory: directory)
            settings.maxImageMB = Double(first.count - 1) / 1_048_576
            store.addImage(first, sourceApp: "Test", sourceBundleID: nil)
            try expect(store.items.isEmpty && store.issue != nil, "Oversized capture was accepted")
            try expect(try imageFiles(directory).isEmpty, "Rejected capture left a file")
            settings.maxImageMB = 20
            settings.maxImageStorageMB = Double(max(first.count, second.count)) / 1_048_576
            store.addImage(first, sourceApp: "Test", sourceBundleID: nil)
            let firstID = store.items[0].id
            let firstURL = store.imageURL(for: store.items[0])!
            store.addImage(second, sourceApp: "Test", sourceBundleID: nil)
            try expect(store.items.count == 1 && store.items[0].id != firstID, "Storage cap did not evict the older image")
            try expect(!FileManager.default.fileExists(atPath: firstURL.path), "Evicted image file was not reclaimed")
            store.clearUnlocked()
            store.addImage(first, sourceApp: "Test", sourceBundleID: nil)
            let lockedID = store.items[0].id
            store.toggleLock(lockedID)
            settings.maxItems = 1
            store.addImage(second, sourceApp: "Test", sourceBundleID: nil)
            try expect(store.items.count == 2, "Locked image consumed count or image storage allowance")
            store.clearUnlocked()
            try expect(store.items.map(\.id) == [lockedID], "Clearing history removed a locked image")
            store.toggleLock(lockedID)
            let unlocked = store.items[0]
            store.cleanup(now: unlocked.lastCopiedAt.addingTimeInterval(48 * 3_600 + 1))
            let remainingFiles = try imageFiles(directory)
            try expect(store.items.isEmpty && remainingFiles.isEmpty, "Expired image or its file survived cleanup")
        }
    }

    static func testLoadFailure() throws {
        try withDirectory { directory, settings in
            let good = ClipboardStore(settings: settings, directory: directory)
            good.addText("preserve", sourceApp: "Test", sourceBundleID: nil)
            let manifest = directory.appendingPathComponent("history.json")
            let original = try Data(contentsOf: manifest)
            let orphan = directory.appendingPathComponent("Images/" + UUID().uuidString + ".png")
            let image = png(0, 0, 255)
            try image.write(to: orphan)
            let corrupt = Data("{invalid history".utf8)
            try corrupt.write(to: manifest, options: .atomic)
            let broken = ClipboardStore(settings: settings, directory: directory)
            try expect(broken.issue != nil, "Load failure was not reported")
            broken.addText("new", sourceApp: "Test", sourceBundleID: nil)
            broken.addImage(image, sourceApp: "Test", sourceBundleID: nil)
            broken.addGroup(name: "New")
            broken.clearUnlocked()
            broken.cleanup()
            try expect(try Data(contentsOf: manifest) == corrupt, "Corrupt history was overwritten")
            try expect(try Data(contentsOf: orphan) == image, "Images were reclaimed after an unsuccessful load")
            var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            json["version"] = 99
            let newer = try JSONSerialization.data(withJSONObject: json)
            try newer.write(to: manifest, options: .atomic)
            let unsupported = ClipboardStore(settings: settings, directory: directory)
            unsupported.addText("new", sourceApp: "Test", sourceBundleID: nil)
            let preserved = try Data(contentsOf: manifest)
            try expect(unsupported.issue != nil && preserved == newer,
                   "Newer history was overwritten")
        }
    }

    static func testImageEvictionOrder() throws {
        try withDirectory { directory, settings in
            let olderSmall = png(255, 0, 0)
            let newerLarge = png(0, 255, 0, size: 128)
            try expect(newerLarge.count > olderSmall.count + 1, "Image fixture sizes do not exercise eviction order")
            let store = ClipboardStore(settings: settings, directory: directory)
            store.addImage(olderSmall, sourceApp: "Test", sourceBundleID: nil)
            store.addImage(newerLarge, sourceApp: "Test", sourceBundleID: nil)
            try expect(store.items.count == 2, "Images were not saved before reducing capacity")
            settings.maxImageStorageMB = Double(newerLarge.count - 1) / 1_048_576
            store.cleanup()
            try expect(store.items.isEmpty, "Cleanup skipped a newer oversized image and retained an older image")
            try expect(try imageFiles(directory).isEmpty, "Evicted image files were not reclaimed")
        }
    }

    static func testWriteFailure() throws {
        try withDirectory { directory, settings in
            let store = ClipboardStore(settings: settings, directory: directory)
            store.addText("original", sourceApp: "Test", sourceBundleID: nil)
            let originalItems = store.items
            let manifest = directory.appendingPathComponent("history.json")
            let backup = directory.appendingPathComponent("history.before-failure.json")
            try FileManager.default.moveItem(at: manifest, to: backup)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            store.addImage(png(255, 128, 0), sourceApp: "Test", sourceBundleID: nil)
            try expect(store.items == originalItems && store.issue != nil, "Failed save changed the published history")
            try expect(try imageFiles(directory).isEmpty, "Failed save left a new image file")
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.moveItem(at: backup, to: manifest)
            let reopened = ClipboardStore(settings: settings, directory: directory)
            try expect(sameItems(reopened.items, originalItems), "Failed save changed the persisted history")
            store.addText("recovered", sourceApp: "Test", sourceBundleID: nil)
            try expect(store.items.count == 2 && store.issue == nil, "Store could not recover from a transient write failure")
        }
    }
}
