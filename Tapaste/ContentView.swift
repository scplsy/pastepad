import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var pasteService: PasteService
    @ObservedObject var monitor: ClipboardMonitor
    var onDismiss: () -> Void
    var onSettings: () -> Void
    var onCopy: (ClipboardItem) -> Bool

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var filter: ClipFilter = .all
    @State private var selectedID: UUID?
    @State private var editor: ClipEditor?
    @State private var draft = ""
    @State private var deletion: PendingDeletion?
    @State private var previewItem: ClipboardItem?
    @State private var creatingItem = false
    @State private var copiedItemID: UUID?
    @State private var copyFeedbackID = UUID()
    @State private var presentationOrder: [UUID] = []
    @State private var groupDirection = 1
    @FocusState private var searchFocused: Bool

    private var visibleItems: [ClipboardItem] {
        items(in: filter)
    }

    /// Keep existing rows where the user saw them for this presentation.
    /// Fresh captures still enter at the top; a new hosting view uses saved recency.
    private var orderedItems: [ClipboardItem] {
        let order = ClipboardPresentationOrder.merging(presentationOrder, current: store.items.map(\.id))
        let itemsByID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        return order.compactMap { itemsByID[$0] }
    }

    private func items(in scope: ClipFilter) -> [ClipboardItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return orderedItems.filter { item in
            let inScope: Bool
            switch scope {
            case .all: inScope = true
            case .locked: inScope = item.isLocked
            case .ungrouped: inScope = item.groupID == nil
            case .group(let id): inScope = item.groupID == id
            }
            return inScope && (search.isEmpty
                || item.text.localizedStandardContains(search)
                || item.note.localizedStandardContains(search))
        }
    }

    private var selectedItem: ClipboardItem? {
        visibleItems.first { $0.id == selectedID } ?? visibleItems.first
    }

    private var groupOrder: [ClipFilter] {
        [.all, .locked, .ungrouped] + store.groups.map { .group($0.id) }
    }

    private var groupAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9)
    }

    private var filterTitle: String {
        switch filter {
        case .all: return L("All items", "全部记录")
        case .locked: return L("Locked items", "已锁定记录")
        case .ungrouped: return L("Ungrouped items", "未分组记录")
        case .group(let id): return store.groups.first { $0.id == id }?.name ?? L("All items", "全部记录")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 22)
                .padding(.top, 16)
            groupFilters
                .padding(.top, 13)
            if !pasteService.accessibilityGranted { permissionBanner }
            if !settings.paused, let status = monitor.status { monitorBanner(status) }
            if settings.paused { pausedBanner }
            groupContent
                .padding(.top, 12)
            if let issue = store.issue { messageBar(issue, isError: true) }
            if let message = pasteService.message { messageBar(message, isError: false) }
            footer
        }
        .frame(minWidth: 360, idealWidth: 600, maxWidth: .infinity,
               minHeight: 420, idealHeight: 650, maxHeight: .infinity)
        .background(GlassSurface())
        .background(keyboardCommands)
        .sheet(item: $editor) { currentEditor in editorView(currentEditor) }
        .sheet(isPresented: $creatingItem) {
            ManualEntryEditor(store: store, initialGroupID: selectedGroupID, initiallyLocked: filter == .locked) { id, groupID in
                query = ""
                filter = groupID.map(ClipFilter.group) ?? .ungrouped
                selectedID = id
                creatingItem = false
            } onCancel: {
                creatingItem = false
            }
        }
        .sheet(item: $previewItem) { item in imagePreview(item) }
        .alert(deletionTitle, isPresented: deletionPresented, presenting: deletion) { pending in
            Button(L("Cancel", "取消"), role: .cancel) { deletion = nil }
            Button(deletionButton(pending), role: .destructive) { performDeletion(pending) }
        } message: { pending in
            Text(deletionMessage(pending))
        }
        .onAppear {
            presentationOrder = store.items.map(\.id)
            selectedID = visibleItems.first?.id
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: store.items.map(\.id)) { ids in
            presentationOrder = ClipboardPresentationOrder.merging(presentationOrder, current: ids)
        }
        .onChange(of: visibleItems.map(\.id)) { ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
        .onChange(of: store.groups.map(\.id)) { ids in
            if case .group(let id) = filter, !ids.contains(id) { filter = .ungrouped }
        }
        .task(id: copyFeedbackID) {
            guard copiedItemID != nil else { return }
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch { return }
            guard !Task.isCancelled else { return }
            copiedItemID = nil
        }
    }

    private var selectedGroupID: UUID? {
        if case .group(let id) = filter { return id }
        return nil
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            searchField
            Button { creatingItem = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(L("New item (⌘N)", "新建条目（⌘N）"))
            .accessibilityLabel(L("New item", "新建条目"))
            .keyboardShortcut("n", modifiers: .command)
            Button {
                settings.paused.toggle()
            } label: {
                Image(systemName: settings.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(settings.paused ? Color.orange : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.045), in: Circle())
            }
            .buttonStyle(.plain)
            .help(settings.paused ? L("Resume recording", "继续记录") : L("Pause recording", "暂停记录"))
            .accessibilityLabel(settings.paused ? L("Resume recording", "继续记录") : L("Pause recording", "暂停记录"))
            Menu {
                Button(L("New item…", "新建条目…")) { creatingItem = true }
                Button(L("New group…", "新建分组…")) { beginEditing(.newGroup) }
                Button(L("Clear unlocked items…", "清空未锁定记录…")) { deletion = .clear }
                    .disabled(!store.items.contains { !$0.isLocked })
                Divider()
                Button(L("Settings…", "设置…"), action: onSettings)
                Button(L("Close", "关闭"), action: onDismiss)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More actions", "更多操作"))
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L("Search \(filterTitle.lowercased()) & notes", "搜索\(filterTitle)与备注"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { pasteSelected() }
                .accessibilityLabel(L("Search clipboard content and notes", "搜索剪贴板内容与备注"))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("Clear search", "清除搜索"))
            } else {
                Text(settings.shortcutLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 37)
        .background(Color.primary.opacity(contrast == .increased ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var groupFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                NativeGroupTabs(
                    segments: [
                        NativeGroupSegment(id: ClipFilter.all.id, title: L("All", "全部")),
                        NativeGroupSegment(id: ClipFilter.locked.id, title: L("Locked", "已锁定"), systemImage: "lock.fill"),
                        NativeGroupSegment(id: ClipFilter.ungrouped.id, title: L("Ungrouped", "未分组"))
                    ] + store.groups.map {
                        NativeGroupSegment(id: ClipFilter.group($0.id).id, title: $0.name, systemImage: "folder", isCustomGroup: true)
                    },
                    selection: filter.id,
                    onSelect: { id in
                        if let value = groupOrder.first(where: { $0.id == id }) { selectGroup(value) }
                    },
                    onContextAction: { id, action in
                        guard let group = store.groups.first(where: { ClipFilter.group($0.id).id == id }) else { return }
                        switch action {
                        case .newItem:
                            selectGroup(.group(group.id))
                            creatingItem = true
                        case .rename: beginEditing(.renameGroup(group))
                        case .delete: deletion = .group(group)
                        }
                    }
                )
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: 28)
                Button { beginEditing(.newGroup) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("New group", "新建分组"))
                .accessibilityLabel(L("New group", "新建分组"))
            }
            .padding(.horizontal, 22)
        }
    }

    private func selectGroup(_ value: ClipFilter) {
        guard value != filter else { return }
        let currentIndex = groupOrder.firstIndex(of: filter) ?? 0
        let nextIndex = groupOrder.firstIndex(of: value) ?? 0
        groupDirection = nextIndex > currentIndex ? 1 : -1
        withAnimation(groupAnimation) {
            filter = value
            selectedID = visibleItems.first?.id
        }
    }

    private func switchGroup(_ step: Int) {
        guard let index = groupOrder.firstIndex(of: filter),
              groupOrder.indices.contains(index + step) else { return }
        selectGroup(groupOrder[index + step])
    }

    private var groupContent: some View {
        ZStack {
            itemList(items: visibleItems, scope: filter, search: query)
                .id(filter)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .move(edge: groupDirection > 0 ? .trailing : .leading),
                    removal: .move(edge: groupDirection > 0 ? .leading : .trailing)
                ))
                .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(GroupSwipeGesture(
            enabled: editor == nil && previewItem == nil && deletion == nil && !creatingItem,
            onSwipe: switchGroup
        ))
    }

    private var permissionBanner: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "cursorarrow.click.2").foregroundStyle(Color.accentColor)
            Text(L("Enable Accessibility to paste directly into other apps.", "开启辅助功能权限，点击条目即可粘贴到其他应用。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(L("Enable", "开启")) { pasteService.requestAccessibility() }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 22)
        .padding(.top, 12)
    }

    private func monitorBanner(_ status: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.orange)
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(status)
            Spacer(minLength: 0)
            Button(L("Settings", "设置"), action: onSettings)
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private var pausedBanner: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.orange).frame(width: 5, height: 5)
            Text(L("Recording paused", "已暂停记录"))
            Spacer()
            Button(L("Resume", "继续")) { settings.paused = false }.buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    private func itemList(items: [ClipboardItem], scope: ClipFilter, search: String) -> some View {
        Group {
            if items.isEmpty {
                emptyState(scope: scope, search: search)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { item in
                                ClipboardRow(
                                    item: item,
                                    image: item.kind == .image ? store.image(for: item) : nil,
                                    groupName: store.groups.first { $0.id == item.groupID }?.name,
                                    selected: selectedID == item.id,
                                    copied: copiedItemID == item.id,
                                    copyFeedbackID: copyFeedbackID,
                                    onPaste: { pasteService.paste(item, dismiss: onDismiss) },
                                    onCopy: { copyItem(item) }
                                )
                                .contextMenu { itemMenu(item) }
                                .id(item.id)
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: items.map(\.id))
                    }
                    .onChange(of: selectedID) { id in
                        if scope == filter, let id, items.contains(where: { $0.id == id }) {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                reader.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(scope: ClipFilter, search: String) -> some View {
        VStack(spacing: 11) {
            Image(systemName: search.isEmpty && scope == .all ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 35, weight: .ultraLight))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 3)
            Text(emptyTitle(scope: scope, search: search)).font(.system(size: 15, weight: .medium))
            Text(emptyDescription(scope: scope, search: search))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if !search.isEmpty {
                Button(L("Clear search", "清除搜索")) { query = "" }.buttonStyle(.borderless)
            } else if scope != .all {
                Button(L("Show all items", "显示全部记录")) { selectGroup(.all) }.buttonStyle(.borderless)
            }
            if search.isEmpty {
                Button(L("New item…", "新建条目…")) { creatingItem = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyTitle(scope: ClipFilter, search: String) -> String {
        if !search.isEmpty { return L("No matching items", "没有找到匹配记录") }
        if scope == .all, monitor.status != nil { return L("No items yet", "还没有记录") }
        switch scope {
        case .all: return L("Ready when you copy", "从下一次复制开始")
        case .locked: return L("Nothing locked yet", "还没有锁定的记录")
        case .ungrouped: return L("No ungrouped items", "没有未分组的记录")
        case .group: return L("This group is empty", "这个分组还是空的")
        }
    }

    private func emptyDescription(scope: ClipFilter, search: String) -> String {
        if !search.isEmpty { return L("Try another word, or search a different group.", "试试其他关键词，或切换分组。") }
        if scope == .all, !settings.paused, monitor.status != nil {
            return L("Open Settings to review clipboard access.", "打开设置，检查剪贴板访问权限。")
        }
        switch scope {
        case .all: return L("Copy text, links, or images. They will appear here automatically.", "复制文字、链接或图片，记录便会自动出现在这里。")
        case .locked: return L("Lock an item from its menu to keep it beyond automatic cleanup.", "在条目菜单中锁定，即可长期保留，不受自动清理影响。")
        case .ungrouped, .group: return L("Use an item's menu to move it between groups.", "通过条目菜单，将记录移动到这个分组。")
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: ClipboardItem) -> some View {
        Button(L("Paste", "粘贴")) { pasteService.paste(item, dismiss: onDismiss) }
        Button(L("Copy", "复制")) { copyItem(item) }
        if item.kind == .image {
            Button(L("Preview image", "预览图片")) { previewItem = item }
        }
        Divider()
        Button(item.note.isEmpty ? L("Add note…", "添加备注…") : L("Edit note…", "编辑备注…")) { beginEditing(.note(item)) }
        Button(item.isLocked ? L("Unlock", "解锁") : L("Lock", "锁定")) { store.toggleLock(item.id) }
        Menu(L("Move to group", "移动到分组")) {
            Button { store.move(item.id, to: nil) } label: {
                Label(L("Ungrouped", "未分组"), systemImage: item.groupID == nil ? "checkmark" : "folder")
            }
            ForEach(store.groups) { group in
                Button { store.move(item.id, to: group.id) } label: {
                    Label(group.name, systemImage: item.groupID == group.id ? "checkmark" : "folder")
                }
            }
        }
        Divider()
        Button(L("Delete", "删除"), role: .destructive) {
            if item.isLocked { deletion = .item(item) } else { store.delete(item.id) }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Settings", "设置"))
            .accessibilityLabel(L("Settings", "设置"))
            Text(appVersion)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(L("App version", "应用版本"))
            Spacer()
            shortcutHint("↑\u{2009}↓", L("select", "选择"))
            shortcutHint("←\u{2009}→", L("group", "分组"))
            shortcutHint("↵", L("paste", "粘贴"))
            shortcutHint("⌘\u{2009}C", L("copy", "复制"))
            shortcutHint("esc", L("close", "关闭"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private func shortcutHint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: true, vertical: false)
            Text(title).font(.system(size: 10)).lineLimit(1)
        }
        .foregroundStyle(.tertiary)
        .padding(.leading, 3)
        .accessibilityHidden(true)
    }

    private func messageBar(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(isError ? Color.orange : Color.accentColor)
            Text(message).lineLimit(2).help(message)
            Spacer(minLength: 0)
            if isError {
                Button { store.issue = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(L("Dismiss message", "关闭提示"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 23)
        .padding(.bottom, 11)
        .accessibilityElement(children: .combine)
    }

    private func beginEditing(_ next: ClipEditor) {
        switch next {
        case .note(let item): draft = item.note
        case .newGroup: draft = ""
        case .renameGroup(let group): draft = group.name
        }
        editor = next
    }

    private func editorView(_ current: ClipEditor) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(current.title).font(.system(size: 18, weight: .semibold))
            if case .note = current {
                Text(L("Notes stay with this item and appear in search.", "备注随条目保存，也可以通过搜索找到。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 140)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)) }
                    .accessibilityLabel(L("Note", "备注"))
            } else {
                TextField(L("Group name", "分组名称"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveEditor(current) }
            }
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) { editor = nil }.keyboardShortcut(.cancelAction)
                Button(L("Save", "保存")) { saveEditor(current) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!current.isNote && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func saveEditor(_ current: ClipEditor) {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch current {
        case .note(let item): store.updateNote(item.id, note: draft)
        case .newGroup:
            guard !name.isEmpty else { return }
            store.addGroup(name: name)
        case .renameGroup(let group):
            guard !name.isEmpty else { return }
            store.renameGroup(group.id, name: name)
        }
        editor = nil
    }

    private func imagePreview(_ item: ClipboardItem) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text(L("Image preview", "图片预览")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { previewItem = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help(L("Close preview", "关闭预览"))
            }
            if let image = store.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L("Clipboard image", "剪贴板图片"))
            } else {
                Text(L("The image could not be loaded.", "无法读取这张图片。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.imageByteCount), countStyle: .file))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Copy", "复制")) { copyItem(item) }
                Button(L("Done", "完成")) { previewItem = nil }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 550, height: 510)
    }

    private var keyboardCommands: some View {
        PanelKeyboardCommands(
            overlayPresented: editor != nil || previewItem != nil || deletion != nil || creatingItem,
            searchFocused: searchFocused,
            searchIsEmpty: query.isEmpty,
            onMove: moveSelection,
            onGroupMove: switchGroup,
            onPaste: pasteSelected,
            onCopy: { if let item = selectedItem { copyItem(item) } },
            onPreview: { if let item = selectedItem, item.kind == .image { previewItem = item } },
            onDismiss: onDismiss
        ).frame(width: 0, height: 0)
    }

    private func moveSelection(_ step: Int) {
        if searchFocused {
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            selectedID = step > 0 ? visibleItems.first?.id : visibleItems.last?.id
            return
        }
        guard !visibleItems.isEmpty else { return }
        let index = visibleItems.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visibleItems[min(max(index + step, 0), visibleItems.count - 1)].id
    }

    private func pasteSelected() {
        if let item = selectedItem { pasteService.paste(item, dismiss: onDismiss) }
    }

    private func copyItem(_ item: ClipboardItem) {
        guard onCopy(item) else {
            if copiedItemID == item.id { copiedItemID = nil }
            return
        }
        copiedItemID = item.id
        copyFeedbackID = UUID()
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })
    }

    private var deletionTitle: String {
        guard let deletion else { return "" }
        switch deletion {
        case .item: return L("Delete locked item?", "删除已锁定记录？")
        case .group: return L("Delete group?", "删除分组？")
        case .clear: return L("Clear clipboard history?", "清空剪贴板历史？")
        }
    }

    private func deletionButton(_ pending: PendingDeletion) -> String {
        if case .clear = pending { return L("Clear unlocked items", "清空未锁定记录") }
        return L("Delete", "删除")
    }

    private func deletionMessage(_ pending: PendingDeletion) -> String {
        switch pending {
        case .item: return L("This locked item will be permanently removed from history.", "这条已锁定记录将从历史中永久删除。")
        case .group(let group): return L("Items in “\(group.name)” will be moved to Ungrouped.", "“\(group.name)”中的条目将移回“未分组”。")
        case .clear: return L("All unlocked items will be removed. Locked items will be kept.", "将删除所有未锁定记录，保留已锁定记录。")
        }
    }

    private func performDeletion(_ pending: PendingDeletion) {
        switch pending {
        case .item(let item): store.delete(item.id)
        case .group(let group): store.deleteGroup(group.id)
        case .clear: store.clearUnlocked()
        }
        deletion = nil
    }
}

private enum ClipFilter: Hashable, Identifiable {
    case all, locked, ungrouped, group(UUID)

    var id: String {
        switch self {
        case .all: return "all"
        case .locked: return "locked"
        case .ungrouped: return "ungrouped"
        case .group(let id): return id.uuidString
        }
    }
}

private enum ClipEditor: Identifiable {
    case note(ClipboardItem), newGroup, renameGroup(ClipGroup)
    var id: String {
        switch self {
        case .note(let item): return "note-\(item.id)"
        case .newGroup: return "new-group"
        case .renameGroup(let group): return "group-\(group.id)"
        }
    }
    var isNote: Bool { if case .note = self { return true }; return false }
    var title: String {
        switch self {
        case .note: return L("Edit note", "编辑备注")
        case .newGroup: return L("New group", "新建分组")
        case .renameGroup: return L("Rename group", "重命名分组")
        }
    }
}

private enum PendingDeletion {
    case item(ClipboardItem), group(ClipGroup), clear
}

@MainActor
private struct ClipboardRow: View {
    let item: ClipboardItem
    let image: NSImage?
    let groupName: String?
    let selected: Bool
    let copied: Bool
    let copyFeedbackID: UUID
    let onPaste: () -> Void
    let onCopy: () -> Void
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onPaste) {
                HStack(alignment: .top, spacing: 11) {
                    contentIcon
                    VStack(alignment: .leading, spacing: 7) {
                        content
                        if !item.note.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "note.text").font(.system(size: 10))
                                Text(item.note).font(.system(size: 11)).lineLimit(2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        metadata
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.kind == .image ? L("Paste image", "粘贴图片") : L("Paste: \(item.text)", "粘贴：\(item.text)"))
            Button(action: onCopy) {
                CopyFeedbackIcon(copied: copied, feedbackID: copyFeedbackID)
                    .background(Color.primary.opacity(hovered || selected ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(copied ? L("Copied", "已复制") : L("Copy", "复制"))
            .accessibilityLabel(copied ? L("Copied", "已复制") : L("Copy item", "复制此条目"))
        }
        .padding(12)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: copied)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        if copied { return Color.green.opacity(contrast == .increased ? 0.19 : 0.12) }
        if selected { return Color.accentColor.opacity(0.075) }
        return Color(nsColor: .controlBackgroundColor).opacity(hovered ? 0.65 : 0.4)
    }

    private var border: Color {
        if copied { return Color.green.opacity(contrast == .increased ? 0.9 : 0.55) }
        if selected { return Color.accentColor.opacity(contrast == .increased ? 0.9 : 0.4) }
        return Color.primary.opacity(contrast == .increased ? 0.35 : 0.055)
    }

    @ViewBuilder private var contentIcon: some View {
        if item.kind == .image {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 82, height: 67)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(L("Image thumbnail", "图片缩略图"))
        } else {
            Image(systemName: isLink ? "link" : "text.alignleft")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .frame(width: 25, height: 25)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var content: some View {
        if item.kind == .image {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Image", "图片")).font(.system(size: 13, weight: .medium))
                Text(imageDetails).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } else {
            Text(item.text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            if item.isLocked {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor)
                    .help(L("Locked; kept until manually deleted", "已锁定，保留至手动删除"))
            }
            if !item.sourceApp.isEmpty { Text(item.sourceApp).lineLimit(1) }
            if !item.sourceApp.isEmpty { Text("·") }
            MinuteTimestamp(date: item.lastCopiedAt)
            if let groupName {
                Text("·")
                Image(systemName: "folder").font(.system(size: 8))
                Text(groupName).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }

    private var isLink: Bool {
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.contains("\n") && (trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"))
    }

    private var imageDetails: String {
        var detail = ByteCountFormatter.string(fromByteCount: Int64(item.imageByteCount), countStyle: .file)
        if let rep = image?.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            detail = "\(rep.pixelsWide) × \(rep.pixelsHigh) · " + detail
        }
        return detail
    }
}

/// Local events are restricted to this panel and leave text editing and IME input intact.
@MainActor
private struct PanelKeyboardCommands: NSViewRepresentable {
    var overlayPresented: Bool
    var searchFocused: Bool
    var searchIsEmpty: Bool
    var onMove: (Int) -> Void
    var onGroupMove: (Int) -> Void
    var onPaste: () -> Void
    var onCopy: () -> Void
    var onPreview: () -> Void
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.configuration = self
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.configuration = self }
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.uninstall() }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var configuration: PanelKeyboardCommands?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return handled ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let configuration, let window = view?.window,
                  event.window === window, window.isKeyWindow,
                  !configuration.overlayPresented, window.attachedSheet == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let textEditor = window.firstResponder as? NSTextView
            if textEditor?.hasMarkedText() == true { return event }
            if event.keyCode == 53, modifiers.isEmpty {
                configuration.onDismiss()
                return nil
            }
            if textEditor != nil && !configuration.searchFocused { return event }
            if modifiers.isEmpty {
                switch event.keyCode {
                case 123 where textEditor == nil || configuration.searchIsEmpty:
                    configuration.onGroupMove(-1); return nil
                case 124 where textEditor == nil || configuration.searchIsEmpty:
                    configuration.onGroupMove(1); return nil
                case 125: configuration.onMove(1); return nil
                case 126: configuration.onMove(-1); return nil
                case 36 where textEditor == nil, 76 where textEditor == nil:
                    configuration.onPaste(); return nil
                case 49 where textEditor == nil: configuration.onPreview(); return nil
                default: break
                }
            }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c", textEditor == nil {
                configuration.onCopy()
                return nil
            }
            return event
        }
    }
}
