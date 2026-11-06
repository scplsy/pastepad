import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var groups: [ClipGroup] = []
    @Published var issue: String?

    private let settings: AppSettings
    private let directory: URL
    private let imagesDirectory: URL
    private let manifestURL: URL
    private var hashes: [UUID: String] = [:]
    private var canWrite = true
    private var subscriptions = Set<AnyCancellable>()

    private nonisolated struct Snapshot: Codable {
        var version: Int
        var items: [ClipboardItem]
        var groups: [ClipGroup]
        var contentHashes: [String: String]
    }

    private enum StoreError: LocalizedError {
        case invalidHistory
        case newerHistory

        var errorDescription: String? {
            switch self {
            case .invalidHistory:
                return L("The saved clipboard history is invalid.", "保存的剪贴板历史记录无效。")
            case .newerHistory:
                return L("This history was created by a newer version of PastePad.", "历史记录由更高版本的 PastePad 创建。")
            }
        }
    }

    init(settings: AppSettings, directory: URL? = nil) {
        self.settings = settings
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Tapaste", isDirectory: true)
        self.imagesDirectory = self.directory.appendingPathComponent("Images", isDirectory: true)
        self.manifestURL = self.directory.appendingPathComponent("history.json")
        load()
        if canWrite {
            cleanup()
            reclaimUnusedImages()
        }

        Publishers.CombineLatest3(
            settings.$retentionHours, settings.$maxItems, settings.$maxImageStorageMB
        )
        .dropFirst()
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.cleanup() }
        }
        .store(in: &subscriptions)

        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.cleanup() }
            }
            .store(in: &subscriptions)
    }

    func addText(_ text: String, sourceApp: String, sourceBundleID: String?) {
        guard canWrite, !text.isEmpty else { return }
        let hash = contentHash(Data(text.utf8), kind: .text)
        var nextItems = items
        var nextHashes = hashes
        let now = Date()
        if let index = nextItems.firstIndex(where: { hashes[$0.id] == hash }) {
            nextItems[index].lastCopiedAt = now
            nextItems[index].sourceApp = sourceApp
            nextItems[index].sourceBundleID = sourceBundleID
        } else {
            let item = ClipboardItem(
                id: UUID(), kind: .text, text: text, imageFileName: nil, imageByteCount: 0,
                sourceApp: sourceApp, sourceBundleID: sourceBundleID, lastCopiedAt: now,
                note: "", groupID: nil, isLocked: false
            )
            nextItems.append(item)
            nextHashes[item.id] = hash
        }
        commit(cleaned(nextItems, now: now), groups: groups, hashes: nextHashes)
    }

    @discardableResult
    func createText(_ text: String, note: String, groupID: UUID?, isLocked: Bool = false) -> UUID? {
        guard canWrite else {
            issue = L(
                "Clipboard history is unavailable. The saved data has been preserved; restart PastePad after resolving the loading issue.",
                "剪贴板历史记录不可用，原有数据已保留。解决读取问题后，请重新启动 PastePad。"
            )
            return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issue = L("Enter some text for the new item.", "请输入新条目的文本内容。")
            return nil
        }
        guard groupID == nil || groups.contains(where: { $0.id == groupID }) else {
            issue = L("The selected group no longer exists. Choose another group.", "所选分组已不存在，请选择其他分组。")
            return nil
        }

        let now = Date()
        let item = ClipboardItem(
            id: UUID(), kind: .text, text: text, imageFileName: nil, imageByteCount: 0,
            sourceApp: L("Manual entry", "手动创建"), sourceBundleID: Bundle.main.bundleIdentifier,
            lastCopiedAt: now, note: note, groupID: groupID, isLocked: isLocked
        )
        // Manual templates stay independent even when their text matches another item.
        let nextItems = cleaned(items + [item], now: now)
        guard nextItems.contains(where: { $0.id == item.id }) else {
            issue = L(
                "The new item could not be kept with the current history limits. Increase the limits or lock the item.",
                "当前历史记录限制无法保留新条目，请提高限制或锁定条目。"
            )
            return nil
        }
        var nextHashes = hashes
        nextHashes[item.id] = contentHash(Data(text.utf8), kind: .text)
        guard commit(nextItems, groups: groups, hashes: nextHashes) else { return nil }
        return item.id
    }

    func addImage(_ data: Data, sourceApp: String, sourceBundleID: String?) {
        guard canWrite else { return }
        let hash = contentHash(data, kind: .image)
        let existingIndex = items.firstIndex(where: { hashes[$0.id] == hash })
        // The per-image cap applies to new captures, not previously saved content.
        if existingIndex == nil {
            guard data.count <= byteLimit(settings.maxImageMB) else {
                issue = L("Image exceeds the maximum size per image.", "图片超过单张大小上限。")
                return
            }
        }
        // Recapturing a locked image preserves it even after storage limits change.
        if existingIndex.map({ !items[$0].isLocked }) ?? true {
            guard data.count <= byteLimit(settings.maxImageStorageMB) else {
                issue = L("Image exceeds the unlocked image storage limit.", "图片超过未锁定图片的存储上限。")
                return
            }
        }
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let image = NSImage(data: data), image.isValid else {
            issue = L("The image is not valid PNG data.", "图片不是有效的 PNG 数据。")
            return
        }

        var nextItems = items
        var nextHashes = hashes
        let now = Date()
        var newlyWrittenFile: URL?
        let item: ClipboardItem
        if let index = existingIndex {
            nextItems[index].lastCopiedAt = now
            nextItems[index].sourceApp = sourceApp
            nextItems[index].sourceBundleID = sourceBundleID
            item = nextItems[index]
        } else {
            let id = UUID()
            item = ClipboardItem(
                id: id, kind: .image, text: "", imageFileName: id.uuidString + ".png",
                imageByteCount: data.count, sourceApp: sourceApp, sourceBundleID: sourceBundleID,
                lastCopiedAt: now, note: "", groupID: nil, isLocked: false
            )
            nextItems.append(item)
            nextHashes[id] = hash
        }
        guard let name = item.imageFileName else { return }
        let fileURL = imagesDirectory.appendingPathComponent(name)
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                newlyWrittenFile = fileURL
            }
            if !commit(cleaned(nextItems, now: now), groups: groups, hashes: nextHashes),
               let newlyWrittenFile {
                // A failed manifest write leaves the previous history intact.
                try? FileManager.default.removeItem(at: newlyWrittenFile)
            }
        } catch {
            issue = failureMessage("Could not save the image.", "无法保存图片。", error: error)
        }
    }

    func updateNote(_ id: UUID, note: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        next[index].note = note
        commit(next, groups: groups, hashes: hashes)
    }

    func recordReuse(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        let now = Date()
        next[index].lastCopiedAt = now
        commit(cleaned(next, now: now), groups: groups, hashes: hashes)
    }

    func toggleLock(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        next[index].isLocked.toggle()
        let now = Date()
        if !next[index].isLocked { next[index].lastCopiedAt = now }
        commit(cleaned(next, now: now), groups: groups, hashes: hashes)
    }

    func move(_ id: UUID, to groupID: UUID?) {
        guard groupID == nil || groups.contains(where: { $0.id == groupID }),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        next[index].groupID = groupID
        commit(next, groups: groups, hashes: hashes)
    }

    func delete(_ id: UUID) {
        commit(items.filter { $0.id != id }, groups: groups, hashes: hashes)
    }

    func clearUnlocked() {
        commit(items.filter(\.isLocked), groups: groups, hashes: hashes)
    }

    func addGroup(name: String) {
        guard let name = validGroupName(name) else { return }
        commit(items, groups: groups + [ClipGroup(id: UUID(), name: name)], hashes: hashes)
    }

    func renameGroup(_ id: UUID, name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }),
              let name = validGroupName(name, excluding: id) else { return }
        var next = groups
        next[index].name = name
        commit(items, groups: next, hashes: hashes)
    }

    func deleteGroup(_ id: UUID) {
        let next = items.map { original -> ClipboardItem in
            var item = original
            if item.groupID == id { item.groupID = nil }
            return item
        }
        commit(next, groups: groups.filter { $0.id != id }, hashes: hashes)
    }

    func cleanup(now: Date = Date()) {
        guard canWrite else { return }
        let next = cleaned(items, now: now)
        if next != items { commit(next, groups: groups, hashes: hashes) }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard item.kind == .image, let name = item.imageFileName, isSafeImageName(name) else { return nil }
        let url = imagesDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func image(for item: ClipboardItem) -> NSImage? {
        imageURL(for: item).flatMap { NSImage(contentsOf: $0) }
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: manifestURL))
            guard snapshot.version == 1 else { throw StoreError.newerHistory }
            guard Set(snapshot.items.map(\.id)).count == snapshot.items.count,
                  Set(snapshot.groups.map(\.id)).count == snapshot.groups.count else {
                throw StoreError.invalidHistory
            }
            let groupIDs = Set(snapshot.groups.map(\.id))
            var loadedHashes: [UUID: String] = [:]
            for item in snapshot.items {
                guard item.imageByteCount >= 0, item.lastCopiedAt.timeIntervalSince1970.isFinite,
                      item.groupID == nil || groupIDs.contains(item.groupID!) else {
                    throw StoreError.invalidHistory
                }
                if item.kind == .image {
                    guard let name = item.imageFileName, isSafeImageName(name),
                          let hash = snapshot.contentHashes[item.id.uuidString],
                          hash.hasPrefix("image:"), hash.count == 70 else {
                        throw StoreError.invalidHistory
                    }
                    loadedHashes[item.id] = hash
                } else {
                    loadedHashes[item.id] = contentHash(Data(item.text.utf8), kind: .text)
                }
            }
            items = sorted(snapshot.items)
            groups = snapshot.groups
            hashes = loadedHashes
            if items.contains(where: { $0.kind == .image && imageURL(for: $0) == nil }) {
                issue = L("Some saved image files are missing.", "部分已保存图片文件丢失。")
            }
        } catch {
            // Do not replace unreadable history with an empty snapshot or reclaim its files.
            canWrite = false
            issue = failureMessage(
                "Could not load clipboard history. The saved data has been preserved.",
                "无法读取剪贴板历史记录，原有数据已保留。", error: error
            )
        }
    }

    @discardableResult
    private func commit(_ nextItems: [ClipboardItem], groups nextGroups: [ClipGroup], hashes nextHashes: [UUID: String]) -> Bool {
        guard canWrite else { return false }
        let ordered = sorted(nextItems)
        let ids = Set(ordered.map(\.id))
        let retainedHashes = nextHashes.filter { ids.contains($0.key) }
        let previousImageNames = Set(items.compactMap(\.imageFileName))
        let nextImageNames = Set(ordered.compactMap(\.imageFileName))
        let removedImages = !previousImageNames.isSubset(of: nextImageNames)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshot = Snapshot(
                version: 1, items: ordered, groups: nextGroups,
                contentHashes: Dictionary(uniqueKeysWithValues: retainedHashes.map { ($0.key.uuidString, $0.value) })
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: manifestURL, options: .atomic)
            items = ordered
            groups = nextGroups
            hashes = retainedHashes
            issue = nil
            if removedImages { reclaimUnusedImages() }
            return true
        } catch {
            issue = failureMessage("Could not save clipboard history.", "无法保存剪贴板历史记录。", error: error)
            return false
        }
    }

    private func cleaned(_ candidates: [ClipboardItem], now: Date) -> [ClipboardItem] {
        let ordered = sorted(candidates)
        let retentionSeconds = max(0, settings.retentionHours) * 3_600
        var unlocked = Array(ordered.filter {
            !$0.isLocked && now.timeIntervalSince($0.lastCopiedAt) < retentionSeconds
        }.prefix(max(0, settings.maxItems)))
        let storageLimit = Decimal(byteLimit(settings.maxImageStorageMB))
        var imageBytes = unlocked.reduce(Decimal(0)) { total, item in
            total + (item.kind == .image ? Decimal(item.imageByteCount) : 0)
        }
        var removedImageIDs = Set<UUID>()
        // Reclaim oldest images first until the unlocked image budget is met.
        for item in unlocked.reversed() where item.kind == .image && imageBytes > storageLimit {
            removedImageIDs.insert(item.id)
            imageBytes -= Decimal(item.imageByteCount)
        }
        unlocked.removeAll { removedImageIDs.contains($0.id) }
        return sorted(ordered.filter(\.isLocked) + unlocked)
    }

    private func reclaimUnusedImages() {
        guard canWrite else { return }
        let referenced = Set(items.compactMap(\.imageFileName))
        do {
            for url in try FileManager.default.contentsOfDirectory(
                at: imagesDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ) where isSafeImageName(url.lastPathComponent) && !referenced.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            issue = failureMessage("Could not remove unused image files.", "无法清理不再使用的图片文件。", error: error)
        }
    }

    private func validGroupName(_ name: String, excluding id: UUID? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            issue = L("Enter a group name.", "请输入分组名称。")
            return nil
        }
        guard !groups.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) else {
            issue = L("A group with this name already exists.", "已存在同名分组。")
            return nil
        }
        return trimmed
    }

    private func contentHash(_ data: Data, kind: ClipKind) -> String {
        kind.rawValue + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isSafeImageName(_ name: String) -> Bool {
        name.hasSuffix(".png") && UUID(uuidString: String(name.dropLast(4))) != nil
    }

    private func sorted(_ candidates: [ClipboardItem]) -> [ClipboardItem] {
        candidates.sorted {
            if $0.lastCopiedAt != $1.lastCopiedAt { return $0.lastCopiedAt > $1.lastCopiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func byteLimit(_ megabytes: Double) -> Int {
        guard megabytes.isFinite, megabytes > 0 else { return 0 }
        let bytes = megabytes * 1_024 * 1_024
        return bytes >= Double(Int.max) ? Int.max : Int(bytes)
    }

    private func failureMessage(_ english: String, _ chinese: String, error: Error) -> String {
        L(english, chinese) + " " + error.localizedDescription
    }
}
