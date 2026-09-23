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
                .toolbar { toolbarContent }
        }
        .navigationTitle("")
        .navigationSubtitle("")
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

    /// 命令面板入口。只有菜单项和快捷键的话没人会发现它，
    /// 而这正是两千多个接口里最该被用到的那个功能。
    private func commandPaletteButton(isPresented: Binding<Bool>) -> some View {
        Button {
            ui.commandPalette = true
        } label: {
            HStack(spacing: DS.space.sm) {
                AppIcon(symbol: "magnifyingglass", size: 10, tint: DS.color.textSecondary)
                Text("跳转接口")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textSecondary)
                Text("⌘K")
                    .font(DS.font.monoTiny)
                    .foregroundStyle(DS.color.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
                            .fill(DS.color.field)
                    )
            }
            .padding(.horizontal, DS.space.md)
            .frame(height: 22)
            .background(DS.color.field.opacity(0.5), in: Capsule())
            .overlay(Capsule().strokeBorder(DS.color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("跨全部项目搜接口并跳转（⌘K）")
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            CommandPalette()
                .environment(store)
                .environment(ui)
        }
    }

    /// 环境切换。原先挂在请求编辑区的元信息栏里，但环境是**项目级**设置：
    /// 换环境影响这个项目的所有请求，放进工具栏才对得上它的作用域。
    /// 色点与内容区顶部的色轨同色，避免打错环境。
    private func environmentMenu(project: Project) -> some View {
        let environment = project.activeEnvironment
        let tone = EnvironmentTone.color(for: environment)

        return Menu {
            Section("环境") {
                ForEach(project.environments) { candidate in
                    Button {
                        store.setActiveEnvironment(projectID: project.id, environmentID: candidate.id)
                    } label: {
                        if candidate.id == environment?.id {
                            Label(candidate.name, systemImage: "checkmark")
                        } else {
                            Text(candidate.name)
                        }
                    }
                }
            }
            Divider()
            Button("管理环境与变量…") { ui.sheet = .environment(project.id) }
        } label: {
            HStack(spacing: DS.space.sm) {
                Circle()
                    .fill(tone)
                    .frame(width: 7, height: 7)
                Text(environment?.name ?? "未选择环境")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textPrimary)
                    .lineLimit(1)
                AppIcon(symbol: "chevron.down", size: 7, weight: .bold, tint: DS.color.textTertiary)
            }
            .padding(.horizontal, DS.space.md)
            .frame(height: 22)
            .background(tone.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tone.opacity(0.35), lineWidth: 1))
        }
        // borderlessButton 会自带一个**左置**的箭头，且 menuIndicator(.hidden) 管不住它；
        // 改用 .button + plain，箭头由 label 自己画在右边。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(environmentHelp(project: project))
        .animation(DS.motion.select, value: environment?.id)
    }

    private func environmentHelp(project: Project) -> String {
        let environment = project.activeEnvironment
        let base = environment?.baseURL.isEmpty == false
            ? "baseURL：\(environment?.baseURL ?? "")"
            : "该环境未设置 baseURL"
        return EnvironmentTone.isProduction(environment) ? "⚠️ 当前是生产环境 · \(base)" : base
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let commandPaletteBinding = Binding<Bool>(
            get: { ui.commandPalette },
            set: { ui.commandPalette = $0 }
        )
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: DS.space.sm) {
                commandPaletteButton(isPresented: commandPaletteBinding)

                if let project = store.activeProject {
                    environmentMenu(project: project)
                }

                Button {
                    guard let id = store.activeProjectID,
                          let url = FileDialogs.openDirectory(message: "选择 Java / Spring 项目根目录") else { return }
                    Task { await store.syncJavaInterfaces(projectID: id, folderURL: url) }
                } label: {
                    AppIcon(symbol: "folder.badge.plus", size: 13, tint: DS.color.textSecondary)
                }
                .help("绑定 Java 项目并同步接口")
                .disabled(store.activeProjectID == nil)

                Button {
                    guard let project = store.activeProject,
                          let path = project.javaSyncFolderPath else { return }
                    Task { await store.syncJavaInterfaces(projectID: project.id, folderURL: URL(fileURLWithPath: path)) }
                } label: {
                    AppIcon(symbol: "arrow.clockwise", size: 13, tint: DS.color.textSecondary)
                }
                .help("重新同步 Java 项目接口")
                .disabled(store.activeProject?.javaSyncFolderPath == nil)

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
}
