import SwiftUI
import ApiClientCore

struct WorkspaceView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            // 环境色轨：测试绿 / 预发黄 / 生产红。
            // 对着真实接口调试时，「发错环境」是真实事故，一条色带是最低成本的护栏。
            EnvironmentRail()

            // 两层标签：项目层负责项目切换，接口层只看当前项目的请求。
            // 多项目时标签不再靠“项目名前缀”区分；单项目时项目层自动隐藏。
            if store.projectsWithTabs.count > 1 {
                ProjectTabBar()
                Rectangle()
                    .fill(DS.color.hairline)
                    .frame(height: 1)
            }

            TabStripView()
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
