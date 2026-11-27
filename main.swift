import SwiftUI
import ApplicationServices

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private var panel: FloatingPanel!
    private let model = PanelModel()
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var lastCloseTime: TimeInterval = 0
    private var menuFront: WindowKey?
    private var menuOrder = [CGWindowID: Int]()
    private var menuPID: pid_t?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "窗格")
        if button.image == nil { button.title = "窗" }
        button.toolTip = "窗格 · 查找窗口"
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let hosting = NSHostingController(rootView: Panel(model: model))
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor

        panel = FloatingPanel(
            contentRect: CGRect(origin: .zero, size: Panel.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self

        model.dismiss = { [weak self] in self?.closePanel() }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            if (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch event.keyCode {
            case 53 where flags.isEmpty: // Esc
                if self.model.confirmCloseAll { self.model.cancelCloseAll() }
                else if self.model.settings { self.model.settings = false; self.model.focusRequest += 1 }
                else if !self.model.query.isEmpty { self.model.query = "" }
                else if self.model.batchMode { self.model.exitBatchMode() }
                else { self.closePanel() }
            default:
                guard self.model.trusted, !self.model.settings else { return event }
                switch event.keyCode {
                case 125, 126: // Down, Up
                    guard flags.isEmpty else { return event }
                    self.model.navigate(event.keyCode == 125 ? 1 : -1)
                case 36, 76: // Return, Enter
                    guard flags.isEmpty || flags == .command else { return event }
                    if let w = self.model.filtered.first(where: { $0.id == self.model.selected }) {
                        if self.model.batchMode {
                            self.model.toggleBatch(w.id)
                        } else {
                            self.model.focus(w, collapse: flags == .command)
                        }
                    }
                default: return event
                }
            }
            return nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible {
            closePanel()
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        model.cancelCloseAll()
        model.exitBatchMode()
        lastCloseTime = ProcessInfo.processInfo.systemUptime
        panel.orderOut(nil)
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    private func show(settings: Bool) {
        guard let button = item.button else { return }
        model.settings = settings
        model.query = ""
        model.grouped = UserDefaults.standard.bool(forKey: "grouped")
        model.refresh(capture: true)

        let buttonScreenRect: CGRect
        if let buttonWindow = button.window {
            buttonScreenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        } else {
            buttonScreenRect = .zero
        }
        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(buttonScreenRect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visibleFrame = targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = Layout.panelFrame(size: Panel.panelSize, anchor: buttonScreenRect,
                                      visibleFrame: visibleFrame, gap: 8, margin: 8)
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { self.model.focusRequest += 1 }

        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePanel()
            }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            menuFront = model.front
            menuOrder = ManagedWindow.stacking()
            menuPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if !panel.isVisible { menuFront = nil }
            closePanel()
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, command) in [("一键专注", "focus"), ("错落排齐", "cascade"), ("关闭所有窗口", "closeAll"), ("撤销上次整理", "undo")] {
                let entry = menu.addItem(withTitle: title, action: #selector(runCommand(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = command
                entry.isEnabled = command != "undo" || model.organizer.canUndo
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: "").target = self
            menu.addItem(withTitle: "退出窗格", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
            if let button = item.button { menu.popUp(positioning: nil, at: .zero, in: button) }
        } else if panel.isVisible {
            closePanel()
        } else if ProcessInfo.processInfo.systemUptime - lastCloseTime < 0.2 {
            // Avoid immediately reopening when clicking the status bar icon just dismissed the panel via resignKey.
            return
        } else {
            show(settings: false)
        }
    }

    @objc private func settings() { show(settings: true) }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard AXIsProcessTrusted(), let command = sender.representedObject as? String else { show(settings: false); return }
        if command == "closeAll" && UserDefaults.standard.bool(forKey: "confirmCloseAll") {
            let count = ManagedWindow.scan(order: ManagedWindow.stacking()).count
            guard count > 0 else {
                item.button?.toolTip = "当前没有可关闭的窗口"
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "关闭全部 \(count) 个窗口？"
            alert.informativeText = "将向所有应用的标准窗口发送关闭指令；有未保存内容的应用会按系统默认弹出保存提示。"
            alert.addButton(withTitle: "全部关闭")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if command == "focus", menuFront == nil {
            let rows = ManagedWindow.scan(order: menuOrder)
            menuFront = (rows.first { $0.visible && $0.id.pid == menuPID } ?? rows.first { $0.visible })?.id
        }
        model.front = menuFront
        model.organize(command)
        item.button?.toolTip = model.message
        if let button = item.button {
            NSAccessibility.post(element: button, notification: .announcementRequested, userInfo: [.announcement: model.message])
        }
        if command == "focus" && menuFront == nil { show(settings: false) }
    }
}

Preferences.register()
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
