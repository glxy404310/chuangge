import CoreGraphics
import Foundation

let area = CGRect(x: -1350, y: 37, width: 1280, height: 780)
let small = CGSize(width: 360, height: 360)
let sizes = [small, small, small, CGSize(width: 1278, height: 779), area.size,
             CGSize(width: 2000, height: 2000)] + Array(repeating: small, count: 50)
for spacing in [24, 32, 44] {
    let origins = Layout.origins(for: sizes, in: area, step: CGSize(width: spacing, height: spacing))
    precondition(origins.count == sizes.count)
    precondition(origins[0] == CGPoint(x: area.minX + 16, y: area.minY + 16))
    precondition(origins[1] == CGPoint(x: origins[0].x + CGFloat(spacing), y: origins[0].y + CGFloat(spacing)))
    precondition(origins[3] == CGPoint(x: area.minX + 2, y: area.minY + 1))
    precondition(origins[4] == area.origin && origins[5] == area.origin)
    for (size, origin) in zip(sizes, origins) {
        let result = CGRect(origin: origin, size: size)
        precondition(result.size == size && area.contains(origin))
        if size.width <= area.width && size.height <= area.height { precondition(area.contains(result)) }
    }
    let wrapped = Layout.origins(for: Array(repeating: small, count: 30), in: area,
                                 step: CGSize(width: spacing, height: spacing))
    precondition(zip(wrapped, wrapped.dropFirst()).contains { $1.y < $0.y && $1.x > wrapped[0].x })
}
precondition(Layout.origins(for: [], in: area, step: .zero).isEmpty)
print("通过：三档间距、折列、副屏坐标、尺寸保持及超大窗口夹紧")

// Floating panel positioning below menu bar with gap and horizontal clamping
let visible = CGRect(x: 0, y: 73, width: 2560, height: 1534) // maxY = 1607 (below menu bar)
let panelSize = CGSize(width: 392, height: 520)
let rightEdgeButton = CGRect(x: 2480, y: 1607, width: 28, height: 37)
let rightPanel = Layout.panelFrame(size: panelSize, anchor: rightEdgeButton, visibleFrame: visible, gap: 8, margin: 8)
precondition(rightPanel.maxY == visible.maxY - 8, "面板顶部必须与菜单栏保持 8pt 间距")
precondition(rightPanel.maxX == visible.maxX - 8, "靠右图标不能超出屏幕右边界")
precondition(rightPanel.size == panelSize)

let centerButton = CGRect(x: 1200, y: 1607, width: 28, height: 37)
let centerPanel = Layout.panelFrame(size: panelSize, anchor: centerButton, visibleFrame: visible, gap: 8, margin: 8)
precondition(centerPanel.maxY == visible.maxY - 8)
precondition(abs(centerPanel.midX - centerButton.midX) <= 1)

let leftEdgeButton = CGRect(x: 4, y: 1607, width: 28, height: 37)
let leftPanel = Layout.panelFrame(size: panelSize, anchor: leftEdgeButton, visibleFrame: visible, gap: 8, margin: 8)
precondition(leftPanel.minX == visible.minX + 8)
precondition(leftPanel.maxY == visible.maxY - 8)
print("通过：菜单栏下方留白定位与左右边界夹紧")

precondition(matches(" SAF 报告 ", app: "Safari", title: "工作报告"))
precondition(matches("resume", app: "预览", title: "Résumé"))
precondition(matches("", app: "终端", title: "工程"))
precondition(!matches("草稿", app: "终端", title: "工程"))
print("通过：标题与应用名过滤")

let suite = "WindowTests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
Preferences.register(in: defaults)
precondition(!defaults.bool(forKey: "hideApps") && defaults.bool(forKey: "grouped")
             && defaults.integer(forKey: "spacing") == 32 && defaults.bool(forKey: "confirmCloseAll")
             && !defaults.bool(forKey: "quitOnCloseAllWindows"))
defaults.set(true, forKey: "hideApps")
defaults.set(false, forKey: "grouped")
defaults.set(44, forKey: "spacing")
defaults.set(false, forKey: "confirmCloseAll")
defaults.set(true, forKey: "quitOnCloseAllWindows")
let reopened = UserDefaults(suiteName: suite)!
Preferences.register(in: reopened)
precondition(reopened.bool(forKey: "hideApps") && !reopened.bool(forKey: "grouped")
             && reopened.integer(forKey: "spacing") == 44 && !reopened.bool(forKey: "confirmCloseAll")
             && reopened.bool(forKey: "quitOnCloseAllWindows"))
print("通过：设置默认值和持久化")

var undo = UndoSnapshot(), completed = 0, attempts = 0
precondition(!undo.available)
undo.record([{ completed += 1; return true }, { attempts += 1; return attempts > 1 }])
undo.record([])
undo.restore()
precondition(undo.available && completed == 1 && attempts == 1)
undo.restore()
precondition(!undo.available && completed == 1 && attempts == 2)
undo.record([{ fatalError("旧快照不应再执行") }])
undo.record([{ true }])
undo.restore()
precondition(!undo.available)
print("通过：快照替换、空操作、撤销及部分失败重试")

var batch = BatchSelection<Int>()
precondition(batch.isEmpty && batch.targetsToClose(all: [1, 2, 3], keepSelected: true).isEmpty)
precondition(batch.targetsToClose(all: [1, 2, 3], keepSelected: false).isEmpty)
batch.toggle(1)
precondition(batch.contains(1) && batch.groupState(for: [1, 2]) == .partial)
batch.toggleGroup([1, 2]) // partial -> all
precondition(batch.groupState(for: [1, 2]) == .all && batch.count == 2)
batch.toggleGroup([1, 2]) // all -> none
precondition(batch.isEmpty)
batch.toggle(1)
batch.toggleAll(visible: [2, 3]) // keeps 1 outside filter while selecting visible 2,3
precondition(batch.items == Set([1, 2, 3]))
batch.invert(visible: [2, 4])
precondition(batch.items == Set([1, 3, 4]))
precondition(batch.targetsToClose(all: [1, 2, 3, 4, 5], keepSelected: false) == [1, 3, 4])
precondition(batch.targetsToClose(all: [1, 2, 3, 4, 5], keepSelected: true) == [2, 5])
batch.prune(valid: Set([1, 2, 5]))
precondition(batch.items == Set([1]))
let quitGroups = BatchSelection<Int>.fullyTargetedGroups(
    all: [(1, "WeChat"), (2, "Chrome"), (3, "Chrome"), (4, "QQ"), (5, "QQ")],
    targetIDs: Set([1, 2, 4, 5])
)
precondition(quitGroups == Set(["WeChat", "QQ"]), "仅全部窗口被关闭的应用才应进入退出集合")
print("通过：批量勾选、整组勾选、过滤全选反选、保留或关闭及整应用退出判定")
