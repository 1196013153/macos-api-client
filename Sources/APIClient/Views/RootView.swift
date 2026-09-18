import AppKit
import SwiftUI
import ApiClientCore

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: DS.metric.sidebarMin,
                    ideal: DS.metric.sidebarIdeal,
                    max: DS.metric.sidebarMax
                )
        } detail: {
            WorkspaceView()
        }
        .navigationTitle(store.activeProject?.name ?? "API Client")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(item: $ui.sheet) { sheet in
            switch sheet {
            case .environment(let projectID):
                EnvironmentSheet(projectID: projectID)
            case .settings:
                SettingsSheet()
            case .requestDetail(let projectID):
                ProjectDetailSheet(projectID: projectID)
            }
        }
        .sheet(item: $ui.prompt) { prompt in
            PromptSheet(prompt: prompt) { ui.prompt = nil }
        }
        .alert(
            ui.confirm?.title ?? "",
            isPresented: Binding(
                get: { ui.confirm != nil },
                set: { if !$0 { ui.confirm = nil } }
            ),
            presenting: ui.confirm
        ) { confirm in
            if let alternateTitle = confirm.alternateTitle {
                Button(alternateTitle) {
                    confirm.onAlternate?()
                    ui.confirm = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            Button(confirm.confirmTitle, role: confirm.isDestructive ? .destructive : nil) {
                confirm.onConfirm()
                ui.confirm = nil
            }
            Button("取消", role: .cancel) { ui.confirm = nil }
        } message: { confirm in
            Text(confirm.message)
        }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                ToastView(notice: notice) { store.clearNotice() }
                    .padding(.bottom, DS.space.xxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(DS.motion.toast, value: store.notice?.id)
        .task(id: store.notice?.id) {
            guard store.notice != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            store.clearNotice()
        }
        .onDisappear {
            store.flushSave()
        }
    }

    private var subtitle: String {
        guard let project = store.activeProject else { return "尚未创建项目" }
        let environment = project.activeEnvironment?.name ?? "未选择环境"
        return "\(project.requests.count) 个接口 · 环境 \(environment) · \(store.visibleSessions.count) 个标签"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let id = store.activeProjectID {
                    ui.sheet = .requestDetail(id)
                }
            } label: {
                AppIcon(symbol: "info.circle", size: 13, tint: DS.color.textSecondary)
            }
            .help("当前项目信息")
            .disabled(store.activeProjectID == nil)

            Button {
                ui.sheet = .settings
            } label: {
                AppIcon(symbol: "gearshape", size: 13, tint: DS.color.textSecondary)
            }
            .help("设置（超时、TLS、数据目录）")
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
