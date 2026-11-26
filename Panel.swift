import AppKit
import SwiftUI
import ApplicationServices

struct AppSection: Identifiable {
    let pid: pid_t
    let app: NSRunningApplication
    let appName: String
    let isAppHidden: Bool
    let windows: [ManagedWindow]
    var id: pid_t { pid }
}

final class PanelModel: ObservableObject {
    @Published var windows = [ManagedWindow]()
    @Published var query = ""
    @Published var grouped = UserDefaults.standard.bool(forKey: "grouped")
    @Published var selected: WindowKey?
    @Published var hovered: WindowKey?
    @Published var front: WindowKey?
    @Published var settings = false
    @Published var trusted = false
    @Published var loading = false
    @Published var message = ""
    @Published var canUndo = false
    @Published var focusRequest = 0
    @Published var headerHeight: CGFloat = 126
    @Published var footerHeight: CGFloat = 38
    var dismiss: () -> Void = {}
    let organizer = Organizer()
    private var generation = 0
    private var messageWorkItem: DispatchWorkItem?
    private let scanner = DispatchQueue(label: "local.chuangge.window-scan", qos: .userInitiated)

    var sections: [AppSection] {
        let rows = windows.filter { matches(query, app: $0.appName, title: $0.title) }
        var buckets = [pid_t: [ManagedWindow]]()
        var rankByPID = [pid_t: Int]()
        for w in rows {
            buckets[w.id.pid, default: []].append(w)
            rankByPID[w.id.pid] = min(rankByPID[w.id.pid] ?? Int.max, w.zOrder)
        }
        return buckets.compactMap { pid, list -> AppSection? in
            guard let first = list.first else { return nil }
            let sortedList = list.sorted { ($0.zOrder, $0.title, $0.id.number) < ($1.zOrder, $1.title, $1.id.number) }
            return AppSection(pid: pid, app: first.app, appName: first.appName,
                              isAppHidden: first.isAppHidden, windows: sortedList)
        }.sorted {
            let lRank = rankByPID[$0.pid] ?? Int.max
            let rRank = rankByPID[$1.pid] ?? Int.max
            return (lRank, $0.appName, $0.pid) < (rRank, $1.appName, $1.pid)
        }
    }

    var filtered: [ManagedWindow] {
        if grouped {
            return sections.flatMap(\.windows)
        }
        return windows.filter { matches(query, app: $0.appName, title: $0.title) }
    }

    func setMessage(_ text: String, autoClear: Bool = true) {
        messageWorkItem?.cancel()
        message = text
        guard autoClear, !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) {
                self?.message = ""
            }
        }
        messageWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    func refresh(capture: Bool = false) {
        generation += 1
        let token = generation
        trusted = AXIsProcessTrusted()
        canUndo = organizer.canUndo
        guard trusted else { windows = []; loading = false; return }
        let order = ManagedWindow.stacking()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if capture {
            front = nil
            windows = []
            selected = nil
            hovered = nil
            setMessage("", autoClear: false)
        }
        loading = true
        scanner.async { [weak self] in
            let rows = ManagedWindow.scan(order: order)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.windows = rows
                if capture {
                    self.front = (rows.first { $0.visible && $0.id.pid == pid } ?? rows.first { $0.visible })?.id
                }
                self.loading = false
                self.selectValid()
            }
        }
    }

    func selectValid() {
        let rows = filtered
        if !rows.contains(where: { $0.id == selected }) { selected = rows.first?.id }
    }

    func navigate(_ delta: Int) {
        let rows = filtered
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selected } ?? 0
        selected = rows[min(max(0, index + delta), rows.count - 1)].id
    }

    func focus(_ w: ManagedWindow, collapse: Bool) {
        dismiss()
        guard w.focus() else {
            setMessage("无法切入该窗口")
            refresh()
            return
        }
        if collapse {
            let result = organizer.collapse(keeping: w,
                                            windows: ManagedWindow.scan(order: ManagedWindow.stacking()),
                                            hideApps: UserDefaults.standard.bool(forKey: "hideApps"))
            canUndo = organizer.canUndo
            setMessage(result)
        }
    }

    func organize(_ action: String) {
        let rows = ManagedWindow.scan(order: ManagedWindow.stacking())
        switch action {
        case "focus":
            let target = rows.first(where: { $0.id == front && $0.visible })
                ?? rows.first(where: { $0.id == selected && $0.visible })
                ?? rows.first(where: { $0.visible })
            guard let target else {
                setMessage("当前桌面没有可专注的前台窗口")
                return
            }
            setMessage(organizer.collapse(keeping: target, windows: rows,
                                          hideApps: UserDefaults.standard.bool(forKey: "hideApps")))
        case "cascade":
            setMessage(organizer.cascade(rows, spacing: UserDefaults.standard.integer(forKey: "spacing")))
        default:
            setMessage(organizer.undo())
        }
        canUndo = organizer.canUndo
        refresh()
    }

    func toggle(_ w: ManagedWindow) {
        let ok = w.isAppHidden ? w.focus() : w.minimize(!w.isMinimized)
        if !ok { setMessage("无法更改窗口状态") }
        refresh()
    }

    func openPrivacy() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

struct Panel: View {
    @ObservedObject var model: PanelModel
    @FocusState private var searchFocus: Bool
    @AppStorage("hideApps") private var hideApps = false
    @AppStorage("grouped") private var defaultGrouped = true
    @AppStorage("spacing") private var spacing = 32

    static let panelSize = CGSize(width: 392, height: 520)
    private let cornerRadius: CGFloat = 16
    private let railInset: CGFloat = 14
    private let shortcuts = "Enter 切入 · ⌘↩ 切入并专注 · ↑↓ 选择 · Esc 关闭"

    var body: some View {
        ZStack {
            VisualEffectBackdrop(material: .popover, blendingMode: .behindWindow)

            if model.settings {
                settingsPage
            } else if !model.trusted {
                permissionPage
            } else {
                mainPage
            }
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .onAppear { searchFocus = true }
        .onChange(of: model.focusRequest) { searchFocus = true }
    }

    // MARK: - Main Window Finder Page

    private var mainPage: some View {
        ZStack(alignment: .top) {
            windowList
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                topFrostedBar
                Spacer(minLength: 0)
                bottomFrostedBar
            }
        }
    }

    private var topFrostedBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Search box
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索应用或窗口标题", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($searchFocus)
                    .onChange(of: model.query) { model.selectValid() }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.selectValid()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
                icon("gearshape", "设置") { model.settings = true }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            // Count + Sort mode
            HStack(spacing: 8) {
                let total = model.windows.count
                let shown = model.filtered.count
                Text(model.query.isEmpty ? "\(total) 个窗口" : "\(shown) / \(total) 个窗口")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.grouped.toggle()
                    model.selectValid()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.grouped ? "square.stack.3d.up" : "clock")
                            .font(.system(size: 11))
                        Text(model.grouped ? "按应用分组" : "最近使用")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }

            // Quick Actions
            HStack(spacing: 8) {
                Button("一键专注") { model.organize("focus") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("错落排齐") { model.organize("cascade") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Button("撤销") { model.organize("undo") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.canUndo)
            }
            .disabled(model.loading)
        }
        .padding(.horizontal, railInset)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(
            // Seamless Gaussian blur fading smoothly downward into the scroll list
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.regularMaterial)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.86),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.bottom, -18)
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 0.5)
            }
            .allowsHitTesting(false)
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(model.headerHeight - height) > 0.5 { model.headerHeight = height }
        }
    }

    private var bottomFrostedBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.message.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text(model.message)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                        )
                )
                .padding(.horizontal, railInset)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                Text(shortcuts)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, railInset)
            .padding(.top, 10)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Seamless upward Gaussian blur connecting scrolling rows with the bottom bar
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(.regularMaterial)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black.opacity(0.72), location: 0.32),
                                    .init(color: .black, location: 0.48),
                                    .init(color: .black, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .padding(.top, -22)
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 0.5)
                }
                .allowsHitTesting(false)
            )
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(model.footerHeight - height) > 0.5 { model.footerHeight = height }
        }
    }

    private var windowList: some View {
        let rows = model.filtered
        let sections = model.grouped ? model.sections : []
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Color.clear.frame(height: model.headerHeight + 4)

                    if rows.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: model.loading ? "ellipsis.circle" : "macwindow")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.tertiary)
                                Text(model.loading ? "正在读取窗口…" : model.query.isEmpty ? "没有可用窗口" : "没有匹配的窗口")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 48)
                            Spacer()
                        }
                    } else if model.grouped {
                        ForEach(sections) { section in
                            sectionHeader(section)
                            ForEach(section.windows) { w in
                                row(w).id(w.id)
                            }
                        }
                    } else {
                        ForEach(rows) { w in
                            row(w).id(w.id)
                        }
                    }

                    Color.clear.frame(height: model.footerHeight + 10)
                }
                .padding(.horizontal, 6)
            }
            .onChange(of: model.selected) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func sectionHeader(_ section: AppSection) -> some View {
        HStack(spacing: 8) {
            appIcon(section.app)
            Text(section.appName)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text("\(section.windows.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer(minLength: 0)
            icon(section.isAppHidden ? "eye.slash" : "eye", section.isAppHidden ? "显示应用" : "隐藏应用") {
                let ok = section.app.isHidden ? section.app.unhide() : section.app.hide()
                if !ok { model.setMessage("无法更改应用可见性") }
                model.refresh()
            }
        }
        // 6pt scroll padding + 8pt horizontal padding = exact 14pt rail alignment with top & bottom bars
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func row(_ w: ManagedWindow) -> some View {
        let isSelected = model.selected == w.id
        let isHovered = model.hovered == w.id
        let showActions = isHovered || isSelected
        let isCurrent = model.front == w.id

        return HStack(spacing: 8) {
            Button {
                model.focus(w, collapse: false)
            } label: {
                HStack(spacing: 8) {
                    if !model.grouped {
                        appIcon(w.app)
                    } else {
                        Circle()
                            .fill(isCurrent ? Color.accentColor : Color.primary.opacity(w.isAppHidden || w.isMinimized ? 0.15 : 0.32))
                            .frame(width: 6, height: 6)
                            .frame(width: 18, alignment: .center)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.title)
                            .font(.system(size: 13))
                            .foregroundStyle(w.isAppHidden || w.isMinimized ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !model.grouped {
                            Text(w.appName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(w.title)

            if showActions {
                HStack(spacing: 2) {
                    icon("scope", "切入并专注") { model.focus(w, collapse: true) }
                    icon(w.isMinimized || w.isAppHidden ? "arrow.up.right.square" : "minus.square",
                         w.isMinimized || w.isAppHidden ? "恢复窗口" : "收起窗口") { model.toggle(w) }
                    icon("xmark", "关闭窗口") {
                        if !w.close() { model.setMessage("无法关闭该窗口") }
                        model.refresh()
                    }
                }
            } else if w.isAppHidden || w.isMinimized || isCurrent {
                Text(w.isAppHidden ? "已隐藏" : w.isMinimized ? "已最小化" : "当前")
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    )
            }
        }
        // Exact 14pt visual rail (6pt outer + 8pt inner) matching top bar, group headers & bottom bar
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .onHover { over in
            if over { model.hovered = w.id }
            else if model.hovered == w.id { model.hovered = nil }
        }
    }

    // MARK: - Settings Page

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                icon("chevron.backward", "返回窗口列表") {
                    model.settings = false
                    model.focusRequest += 1
                }
                Text("设置").font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, railInset)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("一键专注收起方式").font(.system(size: 13, weight: .semibold))
                        Picker("收起方式", selection: $hideApps) {
                            Text("最小化其他窗口").tag(false)
                            Text("隐藏其他应用").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        Text(hideApps ? "保留目标应用的窗口。其他应用如同按下 ⌘H，恢复快，也不占用程序坞。" : "仅保留选中的窗口。同一应用的其他窗口也会最小化到程序坞。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider().opacity(0.5)

                    VStack(alignment: .leading, spacing: 10) {
                        Picker("列表默认视图", selection: $defaultGrouped) {
                            Text("按应用分组").tag(true)
                            Text("最近使用").tag(false)
                        }
                        .onChange(of: defaultGrouped) { _, value in model.grouped = value }

                        Picker("错落排齐间距", selection: $spacing) {
                            Text("紧凑（24 pt）").tag(24)
                            Text("适中（32 pt）").tag(32)
                            Text("宽松（44 pt）").tag(44)
                        }
                    }
                }
                .padding(railInset)
            }

            Divider().opacity(0.5)

            Text(shortcuts)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, railInset)
                .padding(.vertical, 11)
        }
    }

    // MARK: - Permission Page

    private var permissionPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Label("允许窗格访问窗口", systemImage: "macwindow")
                    .font(.system(size: 16, weight: .semibold))
                Text("在系统设置的「隐私与安全性 → 辅助功能」中开启「窗格」，授权生效后此面板会自动刷新。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开辅助功能设置") { model.openPrivacy() }
                    .buttonStyle(.borderedProminent)
                    .task {
                        while !Task.isCancelled {
                            if AXIsProcessTrusted() {
                                model.refresh(capture: true)
                                return
                            }
                            do { try await Task.sleep(for: .seconds(1)) }
                            catch { return }
                        }
                    }
            }
            .padding(railInset + 6)
            Spacer()
            Divider().opacity(0.5)
            Text(shortcuts)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, railInset)
                .padding(.vertical, 11)
        }
    }

    // MARK: - Helpers

    private func appIcon(_ app: NSRunningApplication) -> some View {
        Group {
            if let image = app.icon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }

    private func icon(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .help(name)
    }
}
