import AppKit
import ApplicationServices

// WindowServer supplies Space visibility and stacking order. AX supplies the movable window.
@_silgen_name("_AXUIElementGetWindow")
private func windowID(_ window: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}

private func settable(_ element: AXUIElement, _ key: String) -> Bool {
    var result = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, key as CFString, &result) == .success && result.boolValue
}

struct Display {
    let frame: CGRect
    let usable: CGRect

    static func current() -> [Self] {
        guard let primary = NSScreen.screens.first else { return [] }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { Self(frame: flipped($0.frame), usable: flipped($0.visibleFrame)) }
    }

    func overlap(_ rect: CGRect) -> CGFloat {
        let slice = frame.intersection(rect)
        return slice.isNull ? 0 : slice.width * slice.height
    }
}

struct WindowKey: Hashable {
    let pid: pid_t
    let number: CGWindowID
    let fallback: AXUIElement?
}

struct ManagedWindow: Identifiable {
    let id: WindowKey
    let element: AXUIElement
    let app: NSRunningApplication
    let appName: String
    let title: String
    let isMinimized: Bool
    let isAppHidden: Bool
    let zOrder: Int
    var visible: Bool { zOrder != Int.max && !isMinimized && !isAppHidden }

    var frame: CGRect? {
        Self.readFrame(element)
    }

    static func readFrame(_ element: AXUIElement) -> CGRect? {
        guard let pos = attribute(element, kAXPositionAttribute),
              let dim = attribute(element, kAXSizeAttribute),
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(dim) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              AXValueGetValue(dim as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func move(to origin: CGPoint) -> Bool {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    func minimize(_ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                     value ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    func focus() -> Bool {
        guard !app.isTerminated else { return false }
        if app.isHidden && !app.unhide() { return false }
        if attribute(element, kAXMinimizedAttribute) as? Bool == true && !minimize(false) { return false }
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        NSApp.yieldActivation(to: app)
        let activated = app.activate(options: [.activateAllWindows]) || app.activate()
        if !raised {
            // Some apps (e.g. Electron/Chrome) need a brief beat after unhide/unminimize before raising.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
        }
        return activated || raised
    }

    var canQuitApp: Bool {
        app != .current && app.bundleIdentifier != "com.apple.finder" && !app.isTerminated
    }

    private func pressCloseButton() -> Bool {
        guard let button = attribute(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        let axButton = button as! AXUIElement
        if attribute(axButton, kAXEnabledAttribute) as? Bool == false { return false }
        return AXUIElementPerformAction(axButton, kAXPressAction as CFString) == .success
    }

    func close() -> Bool {
        guard !app.isTerminated else { return true }
        if pressCloseButton() { return true }

        // Many apps disable AXCloseButton while minimized or hidden; briefly restore and retry.
        let wasHidden = app.isHidden
        let wasMinimized = attribute(element, kAXMinimizedAttribute) as? Bool == true
        if wasHidden { _ = app.unhide() }
        if wasMinimized { _ = minimize(false) }
        if (wasHidden || wasMinimized), pressCloseButton() { return true }

        // Fallback: some windows expose an AXClose action directly on the window element.
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success,
           let list = names as? [String], list.contains("AXClose"),
           AXUIElementPerformAction(element, "AXClose" as CFString) == .success {
            return true
        }
        return false
    }

    static func stacking() -> [CGWindowID: Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        var order = [CGWindowID: Int]()
        for (index, info) in list.enumerated() where info[kCGWindowLayer as String] as? Int == 0 {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = index }
        }
        return order
    }

    static func scan(order: [CGWindowID: Int]) -> [Self] {
        var result = [Self]()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != .current {
            let pid = app.processIdentifier
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.35)
            guard let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            let name = app.localizedName ?? "未知应用"
            for w in windows where attribute(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole {
                var number: CGWindowID = 0
                if windowID(w, &number) != .success { number = 0 }
                let minimized = attribute(w, kAXMinimizedAttribute) as? Bool == true
                let rank = order[number] ?? Int.max
                let onScreen = rank != Int.max && !minimized && !app.isHidden
                // Exclude invisible tray-closed windows (off-screen, not minimized, app not hidden).
                guard onScreen || minimized || app.isHidden else { continue }
                if !onScreen, let rect = Self.readFrame(w), rect.width < 2 || rect.height < 2 { continue }
                let title = attribute(w, kAXTitleAttribute) as? String ?? ""
                result.append(Self(id: WindowKey(pid: pid, number: number, fallback: number == 0 ? w : nil),
                                   element: w, app: app, appName: name, title: title.isEmpty ? name : title,
                                   isMinimized: minimized, isAppHidden: app.isHidden,
                                   zOrder: onScreen ? rank : Int.max))
            }
        }
        return result.sorted { ($0.zOrder, $0.appName, $0.title, $0.id.number) < ($1.zOrder, $1.appName, $1.title, $1.id.number) }
    }
}

final class Organizer {
    private var snapshot = UndoSnapshot()
    var canUndo: Bool { snapshot.available }

    func collapse(keeping target: ManagedWindow, windows: [ManagedWindow], hideApps: Bool) -> String {
        var repairs = [() -> Bool]()
        var failed = 0
        if hideApps {
            let activeApps = Set(windows.filter(\.visible).map { $0.app.processIdentifier })
            for app in NSWorkspace.shared.runningApplications
            where app != target.app && app != .current && app.activationPolicy == .regular && !app.isHidden {
                guard activeApps.contains(app.processIdentifier) else { continue }
                if app.hide() { repairs.append { app.isTerminated || !app.isHidden || app.unhide() } }
                else { failed += 1 }
            }
        } else {
            for w in windows where w.visible && w.id != target.id {
                if attribute(w.element, "AXFullScreen") as? Bool == true { continue }
                guard settable(w.element, kAXMinimizedAttribute) else { continue }
                if w.minimize(true) {
                    repairs.append { w.app.isTerminated || w.minimize(false) || !Self.exists(w) }
                } else { failed += 1 }
            }
        }
        snapshot.record(repairs)
        if repairs.isEmpty && failed == 0 {
            return "桌面已专注，无需收起其他窗口"
        }
        let message = hideApps ? "已隐藏 \(repairs.count) 个应用" : "已收起 \(repairs.count) 个窗口"
        return message + (failed > 0 ? "，\(failed) 项未成功" : "")
    }

    private static func exists(_ window: ManagedWindow) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    func cascade(_ windows: [ManagedWindow], spacing: Int) -> String {
        let displays = Display.current()
        var groups = Array(repeating: [(ManagedWindow, CGRect)](), count: displays.count)
        for w in windows where w.visible && settable(w.element, kAXPositionAttribute) {
            guard let rect = w.frame, !rect.isEmpty, attribute(w.element, "AXFullScreen") as? Bool != true,
                  let i = displays.indices.max(by: { displays[$0].overlap(rect) < displays[$1].overlap(rect) }),
                  displays[i].overlap(rect) > 0 else { continue }
            groups[i].append((w, rect))
        }
        var repairs = [() -> Bool]()
        var failed = 0
        // Place back windows first so the raised front windows reveal the earlier title bars.
        for (i, stack) in groups.enumerated() {
            let group = stack.reversed()
            let origins = Layout.origins(for: group.map { $0.1.size }, in: displays[i].usable,
                                         step: CGSize(width: spacing, height: spacing))
            for ((window, rect), point) in zip(group, origins) where rect.origin != point {
                guard window.move(to: point) else { failed += 1; continue }
                repairs.append { window.app.isTerminated || window.move(to: rect.origin) || !Self.exists(window) }
            }
        }
        snapshot.record(repairs)
        if repairs.isEmpty && failed == 0 {
            return "窗口已处于错落排齐位置"
        }
        return "已移动 \(repairs.count) 个窗口" + (failed > 0 ? "，\(failed) 个未能移动" : "")
    }

    func collapse(keepingIds keptIds: Set<WindowKey>, windows: [ManagedWindow], hideApps: Bool) -> String {
        guard !keptIds.isEmpty else { return "请先选择要保留的窗口" }
        var repairs = [() -> Bool]()
        var failed = 0
        if hideApps {
            let keptPIDs = Set(windows.filter { keptIds.contains($0.id) }.map { $0.app.processIdentifier })
            let activeApps = Set(windows.filter(\.visible).map { $0.app.processIdentifier })
            for app in NSWorkspace.shared.runningApplications
            where !keptPIDs.contains(app.processIdentifier) && app != .current && app.activationPolicy == .regular && !app.isHidden {
                guard activeApps.contains(app.processIdentifier) else { continue }
                if app.hide() { repairs.append { app.isTerminated || !app.isHidden || app.unhide() } }
                else { failed += 1 }
            }
        } else {
            for w in windows where w.visible && !keptIds.contains(w.id) {
                if attribute(w.element, "AXFullScreen") as? Bool == true { continue }
                guard settable(w.element, kAXMinimizedAttribute) else { continue }
                if w.minimize(true) {
                    repairs.append { w.app.isTerminated || w.minimize(false) || !Self.exists(w) }
                } else { failed += 1 }
            }
        }
        snapshot.record(repairs)
        if repairs.isEmpty && failed == 0 {
            return "其余窗口已收起"
        }
        let message = hideApps ? "已保留所选，隐藏 \(repairs.count) 个应用" : "已保留所选，收起 \(repairs.count) 个窗口"
        return message + (failed > 0 ? "，\(failed) 项未成功" : "")
    }

    func quitApp(_ app: NSRunningApplication, name: String) -> String {
        guard app != .current, app.bundleIdentifier != "com.apple.finder" else {
            return "访达不支持退出"
        }
        guard !app.isTerminated else { return "\(name) 已退出" }
        return app.terminate() ? "正在退出 \(name)" : "无法退出 \(name)"
    }

    func closeWindows(_ targets: [ManagedWindow], allWindows: [ManagedWindow]? = nil,
                      quitEmptyApps: Bool = false, keptCount: Int = 0) -> String {
        guard !targets.isEmpty else {
            return keptCount > 0 ? "已保留所选，没有其他需要关闭的窗口" : "当前没有可关闭的窗口"
        }

        let targetIDs = Set(targets.map(\.id))
        let quitPIDs: Set<pid_t>
        if quitEmptyApps, let all = allWindows {
            quitPIDs = BatchSelection.fullyTargetedGroups(
                all: all.map { ($0.id, $0.id.pid) },
                targetIDs: targetIDs
            )
        } else {
            quitPIDs = []
        }

        var closed = 0
        var quitApps = 0
        var failed = 0
        var terminatedPIDs = Set<pid_t>()

        for w in targets {
            guard !w.app.isTerminated else { continue }
            if quitPIDs.contains(w.id.pid) && w.canQuitApp {
                if terminatedPIDs.insert(w.id.pid).inserted {
                    if w.app.terminate() { quitApps += 1 }
                    else if w.close() { closed += 1 }
                    else { failed += 1 }
                }
                continue
            }
            if w.close() { closed += 1 }
            else { failed += 1 }
        }

        if closed == 0 && quitApps == 0 && failed == 0 { return "当前没有可关闭的窗口" }
        var parts = [String]()
        if keptCount > 0 { parts.append("已保留 \(keptCount) 个") }
        if quitApps > 0 { parts.append("已退出 \(quitApps) 个应用") }
        if closed > 0 { parts.append("已关闭 \(closed) 个窗口") }
        if failed > 0 {
            parts.append(quitEmptyApps ? "\(failed) 项未能关闭" : "\(failed) 个不支持窗口关闭（可点应用退出）")
        }
        return parts.joined(separator: "，")
    }

    func closeAll(_ windows: [ManagedWindow], quitEmptyApps: Bool = false) -> String {
        closeWindows(windows, allWindows: windows, quitEmptyApps: quitEmptyApps)
    }

    func undo() -> String {
        snapshot.restore()
        return canUndo ? "部分窗口未还原，可再次撤销" : "已撤销上次整理"
    }
}
