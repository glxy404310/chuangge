import CoreGraphics
import Foundation

enum Layout {
    static func origins(for sizes: [CGSize], in area: CGRect, step: CGSize) -> [CGPoint] {
        var column: CGFloat = 16
        var next = CGPoint(x: column, y: 16)
        return sizes.map { size in
            let limitX = max(0, area.width - size.width)
            let limitY = max(0, area.height - size.height)
            if next.x > limitX || next.y > limitY {
                if next.y > 16 {
                    column += step.width
                    if column > limitX { column = 16 }
                }
                next = CGPoint(x: column, y: 16)
            }
            let x = min(next.x, limitX), y = min(next.y, limitY)
            next = CGPoint(x: x + step.width, y: y + step.height)
            return CGPoint(x: area.minX + x, y: area.minY + y)
        }
    }

    /// Computes a floating panel frame in AppKit screen coordinates (origin at bottom-left, Y upward),
    /// anchored cleanly below the menu bar with a visible gap and clamped inside the screen's visible frame.
    static func panelFrame(size: CGSize, anchor: CGRect, visibleFrame: CGRect,
                           gap: CGFloat = 8, margin: CGFloat = 8) -> CGRect {
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - size.width - margin
        let x: CGFloat
        if maxX < minX {
            x = visibleFrame.minX
        } else {
            let idealX = anchor.isEmpty ? (visibleFrame.maxX - size.width - margin) : (anchor.midX - size.width / 2)
            x = min(max(idealX, minX), maxX)
        }

        let topLimit = anchor.isEmpty ? visibleFrame.maxY : min(visibleFrame.maxY, anchor.minY)
        let idealY = topLimit - gap - size.height
        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - gap - size.height)
        let y = min(max(idealY, minY), maxY)

        return CGRect(x: floor(x), y: floor(y), width: size.width, height: size.height)
    }
}

enum Preferences {
    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            "hideApps": false,
            "grouped": true,
            "spacing": 32,
            "confirmCloseAll": true,
            "quitOnCloseAllWindows": false
        ])
    }
}

func matches(_ query: String, app: String, title: String) -> Bool {
    let haystack = app + " " + title
    return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
        haystack.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

struct UndoSnapshot {
    private var repairs: [() -> Bool] = []
    var available: Bool { !repairs.isEmpty }
    mutating func record(_ actions: [() -> Bool]) {
        if !actions.isEmpty { repairs = actions }
    }
    mutating func restore() {
        repairs = repairs.filter { !$0() }
    }
}

enum GroupCheckState: Equatable {
    case none
    case partial
    case all
}

struct BatchSelection<ID: Hashable> {
    private(set) var items = Set<ID>()

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    func contains(_ id: ID) -> Bool { items.contains(id) }

    mutating func toggle(_ id: ID) {
        if items.remove(id) == nil {
            items.insert(id)
        }
    }

    func groupState(for ids: [ID]) -> GroupCheckState {
        guard !ids.isEmpty else { return .none }
        let matched = ids.reduce(0) { $0 + (items.contains($1) ? 1 : 0) }
        if matched == 0 { return .none }
        return matched == ids.count ? .all : .partial
    }

    mutating func toggleGroup(_ ids: [ID]) {
        guard !ids.isEmpty else { return }
        if groupState(for: ids) == .all {
            items.subtract(ids)
        } else {
            items.formUnion(ids)
        }
    }

    mutating func toggleAll(visible ids: [ID]) {
        toggleGroup(ids)
    }

    mutating func invert(visible ids: [ID]) {
        for id in ids { toggle(id) }
    }

    mutating func prune(valid ids: Set<ID>) {
        items.formIntersection(ids)
    }

    mutating func clear() {
        items.removeAll()
    }

    func targetsToClose(all: [ID], keepSelected: Bool) -> [ID] {
        guard !items.isEmpty else { return [] }
        return keepSelected ? all.filter { !items.contains($0) } : all.filter { items.contains($0) }
    }

    static func fullyTargetedGroups<Group: Hashable>(all: [(id: ID, group: Group)], targetIDs: Set<ID>) -> Set<Group> {
        var total = [Group: Int]()
        var targeted = [Group: Int]()
        for entry in all {
            total[entry.group, default: 0] += 1
            if targetIDs.contains(entry.id) {
                targeted[entry.group, default: 0] += 1
            }
        }
        return Set(total.compactMap { group, count in
            count > 0 && targeted[group] == count ? group : nil
        })
    }
}
