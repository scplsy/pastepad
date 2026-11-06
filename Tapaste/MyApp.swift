import SwiftUI
import AppKit
import Combine
import Carbon
import QuartzCore

@main
struct PastePadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings()
    private lazy var store = ClipboardStore(settings: settings)
    private lazy var monitor = ClipboardMonitor(store: store, settings: settings)
    private lazy var pasteService = PasteService(monitor: monitor)
    private let hotKey = GlobalHotKey()
    private var statusItem: NSStatusItem?
    private var panel: ClipboardPanel?
    private var settingsWindow: NSWindow?
    private var messageWindow: NSPanel?
    private var messageDismissal: DispatchWorkItem?
    private var panelHostingView: NSHostingView<AnyView>?
    private var panelPresentation = PanelPresentationState()
    private var subscriptions = Set<AnyCancellable>()

    private var panelIsDismissing: Bool { panelPresentation.phase == .disappearing }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenApplication(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenApplication)
        )
    }

    @objc private func handleOpenApplication(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let reason = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        guard reason != OSType(keyAELaunchedAsLogInItem), reason != OSType(keyAELaunchedAsServiceItem) else { return }
        DispatchQueue.main.async { [weak self] in self?.showPanel(anchoredToMenu: false) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        monitor.start()
        pasteService.$message.compactMap { $0 }.sink { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.panel?.isVisible != true || self.panelIsDismissing else { return }
                self.showMessage(message)
            }
        }.store(in: &subscriptions)
        settings.$showsMenuBar.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &subscriptions)
        updateStatusItem()
        if !registerShortcut(code: settings.hotKeyCode, modifiers: settings.hotKeyModifiers) {
            settings.showsMenuBar = true
            store.issue = L("Your global shortcut is unavailable. Choose another in Settings.", "全局快捷键不可用，请在设置中更换。")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let panel, panel.isVisible, !panelIsDismissing {
            panel.makeKeyAndOrderFront(nil)
        } else if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
        } else {
            showPanel(anchoredToMenu: false)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        let preferences = NSMenuItem(title: L("Settings…", "设置…"), action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit PastePad", "退出 PastePad"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(title: L("Edit", "编辑"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: L("Edit", "编辑"))
        for (title, selector, key) in [(L("Cut", "剪切"), "cut:", "x"), (L("Copy", "复制"), "copy:", "c"), (L("Paste", "粘贴"), "paste:", "v"), (L("Select All", "全选"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func updateStatusItem() {
        if settings.showsMenuBar {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PastePad")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            item.button?.image?.isTemplate = true
            item.button?.toolTip = "PastePad · \(settings.shortcutLabel)"
            item.button?.target = self
            item.button?.action = #selector(toggleFromMenu)
            // Decide on mouse down, before the resign-key callback from this
            // same status-item click can dismiss the panel before mouse up.
            item.button?.sendAction(on: .leftMouseDown)
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func toggleFromMenu() {
        if panelPresentation.wantsVisible { dismissPanel() }
        else { showPanel(anchoredToMenu: true) }
    }

    private func registerShortcut(code: UInt32, modifiers: UInt32) -> Bool {
        hotKey.register(keyCode: code, modifiers: modifiers) { [weak self] in
            guard let self else { return }
            if self.panelPresentation.wantsVisible { self.dismissPanel() }
            else { self.showPanel(anchoredToMenu: false) }
        }
    }

    private func showPanel(anchoredToMenu: Bool) {
        guard !panelPresentation.wantsVisible else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        let reversingDismissal = panel?.isVisible == true && panelIsDismissing
        guard let transitionID = panelPresentation.beginShow() else { return }
        // Always cancel an older paste request, while retaining the target if
        // this rapid reversal arrives before focus has returned to that app.
        pasteService.rememberTarget(preservingCurrentTarget:
            reversingDismissal && settingsWindow?.isKeyWindow != true
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        )
        store.cleanup()
        let window: ClipboardPanel
        if let panel { window = panel }
        else {
            window = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 650), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.hidesOnDeactivate = false
            window.animationBehavior = .none
            window.delegate = self
            window.title = "PastePad"
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            window.contentView = host
            panelHostingView = host
            panel = window
        }
        // Reuse the AppKit hosting view while starting a fresh SwiftUI session.
        // Clipboard order/search/selection reset once per actual presentation.
        panelHostingView?.rootView = AnyView(ContentView(
            store: store, settings: settings, pasteService: pasteService, monitor: monitor,
            onDismiss: { [weak self] in self?.dismissPanel() },
            onSettings: { [weak self] in self?.showSettings() },
            onCopy: { [weak self] item in
                guard let self else { return false }
                self.pasteService.message = nil
                return self.monitor.copy(item)
            }
        ).id(UUID()))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = NSSize(width: min(600, visible.width - 24), height: min(650, visible.height - 24))
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        if anchoredToMenu, let button = statusItem?.button, let buttonWindow = button.window {
            let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        }
        origin.x = max(visible.minX + 12, min(origin.x, visible.maxX - size.width - 12))
        origin.y = max(visible.minY + 12, min(origin.y, visible.maxY - size.height - 12))
        let destination = NSRect(origin: origin, size: size)
        // Present immediately as before. Replacing a pending fade with a
        // zero-duration animation also makes rapid close/reopen stay visible.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1
        }
        window.setFrame(destination, display: true)
        window.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        panelPresentation.finishShow(transitionID)
    }

    private func dismissPanel(restoreFocus: Bool = true) {
        guard let panel, panel.isVisible,
              let transitionID = panelPresentation.beginDismiss() else { return }
        panel.ignoresMouseEvents = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            panelPresentation.finishDismiss(transitionID)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    guard let self, self.panelPresentation.finishDismiss(transitionID) else { return }
                    panel?.orderOut(nil)
                }
            }
        }
        if restoreFocus,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let target = pasteService.targetApplication, !target.isTerminated {
            target.activate(options: [])
        }
    }

    private func showMessage(_ message: String) {
        messageDismissal?.cancel()
        messageWindow?.orderOut(nil)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 76), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView:
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(Color.accentColor)
                Text(message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(width: 420, height: 76)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        )
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.minY + 64))
        }
        window.orderFrontRegardless()
        messageWindow = window
        let dismissal = DispatchWorkItem { [weak self, weak window] in
            window?.orderOut(nil)
            if self?.pasteService.message == message { self?.pasteService.message = nil }
        }
        messageDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        let generation = panelPresentation.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelPresentation.generation == generation,
                  self.panelPresentation.wantsVisible,
                  self.panel?.isKeyWindow == false, self.panel?.attachedSheet == nil else { return }
            // Window-server focus loss can precede dispatch of the button's
            // mouseDown. Leave that click to the status item's single toggle.
            if NSEvent.pressedMouseButtons & 1 != 0,
               let button = self.statusItem?.button, let window = button.window {
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                if NSMouseInRect(NSEvent.mouseLocation, rect, false) { return }
            }
            self.dismissPanel(restoreFocus: false)
        }
    }

    @objc private func showSettings() {
        dismissPanel(restoreFocus: false)
        if settingsWindow == nil {
            let root = SettingsView(settings: settings, store: store, monitor: monitor, pasteService: pasteService) { [weak self] code, modifiers in
                guard let self, self.registerShortcut(code: code, modifiers: modifiers) else { return false }
                self.settings.hotKeyCode = code
                self.settings.hotKeyModifiers = modifiers
                self.statusItem?.button?.toolTip = "PastePad · \(self.settings.shortcutLabel)"
                return true
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = L("PastePad Settings", "PastePad 设置")
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 760, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
