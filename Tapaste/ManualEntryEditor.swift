import SwiftUI

@MainActor
struct ManualEntryEditor: View {
    @ObservedObject var store: ClipboardStore
    let onCreated: (UUID, UUID?) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @State private var note = ""
    @State private var groupID: UUID?
    @State private var isLocked: Bool
    @State private var error: String?
    @FocusState private var contentFocused: Bool

    init(store: ClipboardStore, initialGroupID: UUID?, initiallyLocked: Bool,
         onCreated: @escaping (UUID, UUID?) -> Void, onCancel: @escaping () -> Void) {
        self.store = store
        self.onCreated = onCreated
        self.onCancel = onCancel
        _groupID = State(initialValue: initialGroupID)
        _isLocked = State(initialValue: initiallyLocked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L("New item", "新建条目"), systemImage: "square.and.pencil")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("⌘↵").font(.caption).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Content", "正文")).font(.callout.weight(.medium))
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($contentFocused)
                    .padding(8)
                    .frame(height: 155)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)) }
                    .accessibilityLabel(L("Item content", "条目正文"))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Note (optional)", "备注（可选）")).font(.callout.weight(.medium))
                TextEditor(text: $note)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .frame(height: 52)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)) }
                    .accessibilityLabel(L("Item note", "条目备注"))
            }
            HStack(spacing: 20) {
                Picker(L("Group", "分组"), selection: $groupID) {
                    Text(L("Ungrouped", "未分组")).tag(Optional<UUID>.none)
                    ForEach(store.groups) { group in Text(group.name).tag(Optional(group.id)) }
                }
                Toggle(L("Lock item", "锁定条目"), isOn: $isLocked)
                    .toggleStyle(.checkbox)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(L("Return inserts a new line.", "回车换行，⌘回车保存。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel", "取消"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Create", "创建"), action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { contentFocused = true }
        .onChange(of: store.groups.map(\.id)) { ids in
            if let groupID, !ids.contains(groupID) { self.groupID = nil }
        }
    }

    private func create() {
        guard let id = store.createText(text, note: note, groupID: groupID, isLocked: isLocked) else {
            error = store.issue ?? L("Could not create this item.", "无法创建条目。")
            return
        }
        onCreated(id, groupID)
    }
}

struct MinuteTimestamp: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(label(relativeTo: context.date))
                .lineLimit(1)
                .help(date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func label(relativeTo now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return L("Just now", "刚刚") }
        if minutes < 60 { return L("\(minutes) min ago", "\(minutes) 分钟前") }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
