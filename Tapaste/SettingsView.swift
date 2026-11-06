import SwiftUI
import AppKit
import ServiceManagement
import Carbon
import UniformTypeIdentifiers

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, history, privacy

    var id: Self { self }
    var title: String {
        switch self {
        case .general: return L("General", "通用")
        case .history: return L("History", "历史记录")
        case .privacy: return L("Privacy", "隐私")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "hand.raised"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return L("Make PastePad fit your workflow.", "设置启动方式与快捷键。")
        case .history: return L("Choose what to keep and for how long.", "管理保留时间与本地存储空间。")
        case .privacy: return L("Control access and excluded applications.", "管理系统权限与排除的应用。")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ClipboardStore
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var pasteService: PasteService
    var onShortcutChange: (UInt32, UInt32) -> Bool
    @State private var selection: SettingsPage? = .general
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var shortcutCode: UInt32 = 9
    @State private var command = true
    @State private var shift = true
    @State private var option = false
    @State private var control = false
    @State private var shortcutError: String?
    @State private var confirmingClear = false
    @State private var permissionRefresh = UUID()

    private var page: SettingsPage { selection ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.title).font(.system(size: 22, weight: .semibold))
                    Text(page.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 20)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch page {
                        case .general: general
                        case .history: history
                        case .privacy: privacy
                        }
                        if let issue = store.issue { issueNotice(issue) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 26)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 520, idealHeight: 560)
        .onAppear { loadShortcut(); refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginStatus()
            permissionRefresh = UUID()
        }
        .alert(L("Clear unlocked history?", "清空未锁定记录？"), isPresented: $confirmingClear) {
            Button(L("Cancel", "取消"), role: .cancel) {}
            Button(L("Clear", "清空"), role: .destructive) { store.clearUnlocked() }
        } message: {
            Text(L("Locked items and groups will be kept. This cannot be undone.", "锁定条目和分组会保留。此操作无法撤销。"))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.tint)
                Text("PastePad").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.top, 29)
            .padding(.bottom, 24)

            List(selection: $selection) {
                ForEach(SettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.symbol).tag(page)
                        .padding(.vertical, 3)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: 10) {
                Button(L("Quit PastePad", "退出 PastePad")) { NSApp.terminate(nil) }
                    .buttonStyle(.borderless).font(.callout)
            }
            .padding(18)
        }
        .frame(width: 170)
        .background(.regularMaterial)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup(L("Startup & access", "启动与入口")) {
                settingsToggle(L("Show in menu bar", "显示菜单栏图标"), detail: L("Use the shortcut or reopen PastePad when hidden.", "隐藏后仍可用快捷键或重新打开应用唤起。"), isOn: $settings.showsMenuBar)
                Divider()
                settingsToggle(L("Launch at login", "登录时启动"), isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { enabled in updateLogin(enabled) }
                if let loginError { smallNote(loginError) }
                Divider()
                settingsToggle(L("Pause clipboard history", "暂停记录剪贴板"), isOn: $settings.paused)
            }
            settingsGroup(L("Global shortcut", "全局快捷键")) {
                HStack {
                    Text(L("Open clipboard history", "唤起剪贴板"))
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(settings.shortcutKeys, id: \.self) { key in
                            Text(verbatim: key)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 6)
                                .frame(minWidth: 25, minHeight: 25)
                                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(settings.shortcutLabel)
                }
                Divider()
                HStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Toggle("⌃", isOn: $control).help(L("Control", "Control 键"))
                        Toggle("⌥", isOn: $option).help(L("Option", "Option 键"))
                        Toggle("⇧", isOn: $shift).help(L("Shift", "Shift 键"))
                        Toggle("⌘", isOn: $command).help(L("Command", "Command 键"))
                    }.toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                    Picker(L("Key", "按键"), selection: $shortcutCode) {
                        ForEach(AppSettings.keyLabels.keys.sorted(by: { AppSettings.keyLabels[$0]! < AppSettings.keyLabels[$1]! }), id: \.self) { code in
                            Text(AppSettings.keyLabels[code]!).tag(code)
                        }
                    }
                    .labelsHidden().frame(width: 76)
                    .accessibilityLabel(L("Shortcut key", "快捷键按键"))
                }
                HStack {
                    if let shortcutError {
                        Text(shortcutError).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(L("Apply shortcut", "应用快捷键")) { applyShortcut() }
                        .disabled(!command && !control && !option)
                }
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup(L("Automatic cleanup", "自动清理")) {
                numberRow(L("Retention period", "保留时间"), unit: L("hours", "小时"), value: $settings.retentionHours, range: 1...8760)
                Divider()
                numberRow(L("Unlocked items", "未锁定条目上限"), unit: L("items", "条"), value: Binding(get: { Double(settings.maxItems) }, set: { settings.maxItems = Int($0) }), range: 1...10000)
                smallNote(L("The oldest unlocked items are removed when either limit is reached. Locked items are kept; unlocking starts a new retention period.", "达到任一限制时清理最旧记录。锁定条目不受限制，解锁后重新计算保留时间。"))
            }
            settingsGroup(L("Image storage", "图片存储")) {
                numberRow(L("Maximum new image", "新图片单张上限"), unit: "MB", value: $settings.maxImageMB, range: 1...1024)
                Divider()
                numberRow(L("Unlocked images total", "未锁定图片总量"), unit: "MB", value: $settings.maxImageStorageMB, range: 1...10240)
                smallNote(L("Original resolution is retained. Oversized new images are skipped; reaching the total limit removes the oldest unlocked images.", "保留原始分辨率。超过单张上限的新图片会被跳过；总量超限时清理最旧的未锁定图片。"))
            }
            HStack(spacing: 14) {
                Button(L("Show local data", "查看本地数据")) { showLocalData() }
                Spacer()
                Button(L("Clear unlocked history…", "清空未锁定记录…"), role: .destructive) { confirmingClear = true }
            }
            .padding(.top, 1)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup(L("System permissions", "系统权限")) {
                VStack(alignment: .leading, spacing: 9) {
                    Label(L("Clipboard reading", "剪贴板读取"), systemImage: "doc.on.clipboard")
                        .font(.body.weight(.medium))
                    smallNote(monitor.status ?? L("Clipboard monitoring is ready.", "剪贴板监听已就绪。"))
                    HStack(spacing: 10) {
                        Button(L("Allow reading", "允许读取")) { monitor.requestPasteboardAccess() }
                        Button(L("System Settings…", "系统设置…")) { monitor.openPasteboardSettings() }
                            .buttonStyle(.borderless)
                    }
                }
                Divider().padding(.vertical, 2)
                directPastePermission.id(permissionRefresh)
            }
            settingsGroup(L("Excluded applications", "排除的应用")) {
                if settings.excludedBundleIDs.isEmpty {
                    smallNote(L("No applications excluded.", "尚未排除任何应用。"))
                } else {
                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(applicationName(bundleID)).lineLimit(1)
                                Text(bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { settings.excludedBundleIDs.removeAll { $0 == bundleID } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(L("Remove exclusion", "移除排除项"))
                            .accessibilityLabel(L("Remove \(applicationName(bundleID))", "移除 \(applicationName(bundleID))"))
                        }
                        if bundleID != settings.excludedBundleIDs.last { Divider() }
                    }
                }
                HStack {
                    Button(L("Add application…", "添加应用…")) { addExcludedApplication() }
                    Spacer()
                }
                smallNote(L("New copies from these apps are skipped. Existing history is kept.", "跳过这些应用中新复制的内容，保留已有历史。"))
            }
            smallNote(L("Content marked as sensitive, temporary, or automatically generated is skipped. Unmarked passwords cannot be reliably detected; pause recording or exclude apps when needed.", "跳过源应用标记为敏感、临时或自动生成的内容；无法可靠识别未标记的密码，可按需暂停记录或排除应用。"))
        }
    }

    private var directPastePermission: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(L("Direct paste", "直接粘贴"), systemImage: "keyboard")
                    .font(.body.weight(.medium))
                Spacer()
                Label(pasteService.accessibilityGranted ? L("Allowed", "已授权") : L("Not allowed", "未授权"), systemImage: pasteService.accessibilityGranted ? "checkmark.circle.fill" : "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            smallNote(L("Accessibility access lets PastePad paste into the previous app. Without it, copy an item and press ⌘V yourself.", "辅助功能权限允许粘贴回原应用；未授权时仍可复制，再手动按 ⌘V。"))
            HStack {
                Button(pasteService.accessibilityGranted ? L("System Settings…", "系统设置…") : L("Grant access…", "前往授权…")) {
                    if pasteService.accessibilityGranted { pasteService.openAccessibilitySettings() }
                    else { pasteService.requestAccessibility() }
                    permissionRefresh = UUID()
                }
                Spacer()
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    private func settingsToggle(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(title)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func smallNote(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func numberRow(_ title: String, unit: String, value: Binding<Double>, range: ClosedRange<Int>) -> some View {
        SettingsNumberRow(title: title, unit: unit, value: value, range: range)
    }

    private func issueNotice(_ issue: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(issue).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.issue = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help(L("Dismiss", "关闭提示"))
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadShortcut() {
        shortcutCode = settings.hotKeyCode
        command = settings.hotKeyModifiers & UInt32(cmdKey) != 0
        shift = settings.hotKeyModifiers & UInt32(shiftKey) != 0
        control = settings.hotKeyModifiers & UInt32(controlKey) != 0
        option = settings.hotKeyModifiers & UInt32(optionKey) != 0
    }

    private func updateLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = SMAppService.mainApp.status == .requiresApproval ? L("Enable PastePad in System Settings → General → Login Items.", "请在系统设置 → 通用 → 登录项中允许 PastePad。") : nil
        } catch {
            loginError = error.localizedDescription
            loginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = L("Enable PastePad in System Settings → General → Login Items.", "请在系统设置 → 通用 → 登录项中允许 PastePad。")
        }
    }

    private func applyShortcut() {
        var modifiers: UInt32 = 0
        if command { modifiers |= UInt32(cmdKey) }
        if shift { modifiers |= UInt32(shiftKey) }
        if control { modifiers |= UInt32(controlKey) }
        if option { modifiers |= UInt32(optionKey) }
        shortcutError = onShortcutChange(shortcutCode, modifiers) ? nil : L("This shortcut is unavailable. Your previous shortcut is still active.", "该快捷键不可用，原快捷键仍然有效。")
    }

    private func showLocalData() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tapaste", isDirectory: true)
        NSWorkspace.shared.open(folder)
    }

    private func applicationName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addExcludedApplication() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        if picker.runModal() == .OK {
            for url in picker.urls {
                if let bundleID = Bundle(url: url)?.bundleIdentifier, !settings.excludedBundleIDs.contains(bundleID) {
                    settings.excludedBundleIDs.append(bundleID)
                }
            }
        }
    }
}

private struct SettingsNumberRow: View {
    let title: String
    let unit: String
    @Binding var value: Double
    let range: ClosedRange<Int>
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(title)
                Spacer(minLength: 14)
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 86)
                    .focused($focused)
                    .accessibilityLabel(title)
                    .accessibilityHint(L("Enter a whole number from \(range.lowerBound) to \(range.upperBound). Press Return to save.", "输入 \(range.lowerBound) 至 \(range.upperBound) 的整数，按回车保存。"))
                    .onSubmit { commit() }
                Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = String(Int(value.rounded())) }
        .onChange(of: focused) { isFocused in if !isFocused { commit() } }
        .onChange(of: value) { newValue in
            if !focused { draft = String(Int(newValue.rounded())); error = nil }
        }
        .onChange(of: draft) { _ in error = nil }
        .onDisappear { commit() }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(text), range.contains(number) else {
            error = L("Enter a whole number from \(range.lowerBound) to \(range.upperBound).", "请输入 \(range.lowerBound) 至 \(range.upperBound) 的整数。")
            return
        }
        error = nil
        draft = String(number)
        // Settings trigger cleanup, so save only a complete, validated edit.
        if value != Double(number) { value = Double(number) }
    }
}
