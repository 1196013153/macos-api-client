import SwiftUI
import ApiClientCore

struct WorkspaceView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            // 顶层项目标签：只在「同时打开了多个项目」时出现。
            // 只开了一个项目就退化为一层，省掉没有信息量的一行。
            if store.projectsWithTabs.count > 1 {
                ProjectTabBar()
                hairline
            }

            // 下层是当前项目自己的请求标签。
            TabStripView()
            hairline
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.color.canvas)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
    }

    @ViewBuilder
    private var content: some View {
        if let session = store.activeSession {
            RequestWorkspaceView(session: session)
        } else {
            EmptyState(
                art: .tabs,
                title: "没有打开的标签页",
                subtitle: "在左侧点击任意接口打开，或新建一个请求开始调试",
                actionTitle: "新建请求",
                action: { store.newDraftTab() }
            )
        }
    }
}

/// 请求编辑区 + 响应区，中间是可拖拽分隔条。
struct RequestWorkspaceView: View {
    let session: TabSession

    var body: some View {
        VSplitView {
            RequestEditorView(session: session)
                .frame(minHeight: 220, idealHeight: 340)

            ResponsePanelView(session: session)
                .frame(minHeight: 160)
        }
    }
}
