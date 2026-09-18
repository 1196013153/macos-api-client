import SwiftUI
import ApiClientCore

/// 关闭标签的统一入口：有未保存修改时先问一句，而不是让 ⌘W / 悬停的 × 悄悄丢掉改动。
///
/// 所有关标签的路径（标签上的 ×、右键菜单、标签条菜单、项目标签、菜单栏快捷键）都走这里；
/// 没有脏标签时直接执行，不打扰。
@MainActor
enum TabClosing {

    /// 关闭 `ids` 里的标签；`perform` 是真正执行关闭的动作（单个 / 其他 / 全部各不相同）。
    static func close(_ ids: [UUID], store: AppStore, ui: UIState, perform: @escaping () -> Void) {
        let dirty = ids.compactMap { store.session(id: $0) }.filter(\.isDirty)
        guard !dirty.isEmpty else {
            perform()
            return
        }

        let title = dirty.count == 1
            ? "「\(dirty[0].displayName)」有未保存的修改"
            : "\(dirty.count) 个标签有未保存的修改"
        ui.askConfirm(
            title: title,
            message: "关闭后这些修改会丢失。",
            confirmTitle: "不保存",
            alternateTitle: dirty.count == 1 ? "保存并关闭" : "全部保存并关闭",
            onAlternate: {
                // 任何一个保存失败都不关：失败的那一个已经弹了提示，留着让用户处理。
                let allSaved = dirty.allSatisfy { store.saveTab(tabID: $0.id) }
                if allSaved { perform() }
            },
            onConfirm: perform
        )
    }

    static func close(_ id: UUID, store: AppStore, ui: UIState) {
        close([id], store: store, ui: ui) { store.closeTab(id: id) }
    }

    static func closeOthers(keeping id: UUID, store: AppStore, ui: UIState) {
        let others = store.visibleSessions.map(\.id).filter { $0 != id }
        close(others, store: store, ui: ui) { store.closeOtherTabs(keeping: id) }
    }

    static func closeToTheRight(of id: UUID, store: AppStore, ui: UIState) {
        let tabs = store.visibleSessions
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let right = tabs.dropFirst(index + 1).map(\.id)
        close(right, store: store, ui: ui) { right.forEach { store.closeTab(id: $0) } }
    }

    static func closeAll(for projectID: UUID, store: AppStore, ui: UIState) {
        let ids = store.sessions.filter { $0.projectID == projectID }.map(\.id)
        close(ids, store: store, ui: ui) { store.closeAllTabs(for: projectID) }
    }

    static func closeAll(store: AppStore, ui: UIState) {
        close(store.sessions.map(\.id), store: store, ui: ui) { store.closeAllTabs() }
    }
}
