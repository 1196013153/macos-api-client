import SwiftUI
import ApiClientCore

/// 项目切换面板（侧边栏头部点开后浮出）。
///
/// 没有用原生 `Menu`：它会把带固定尺寸的自定义 label 压成一行，
/// 两行文字 + 品牌标记的结构在真实窗口里会塌掉。自己画一个 popover
/// 反而能显示更多信息（接口数、当前环境）并统一视觉。
struct ProjectMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("切换项目")

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(store.projects) { project in
                        projectRow(project)
                    }
                }
            }
            .frame(maxHeight: 216)

            divider

            action(title: "新建项目…", symbol: "plus") {
                onDismiss()
                ui.ask(title: "新建项目", placeholder: "项目名称", confirmTitle: "创建") { name in
                    store.createProject(name: name)
                }
            }
            action(title: "重命名当前项目…", symbol: "pencil") {
                guard let project = store.activeProject else { return }
                onDismiss()
                ui.ask(
                    title: "重命名项目",
                    placeholder: "项目名称",
                    initialValue: project.name,
                    confirmTitle: "保存"
                ) { name in
                    store.renameProject(id: project.id, to: name)
                }
            }
            action(title: "复制当前项目", symbol: "doc.on.doc") {
                guard let id = store.activeProjectID else { return }
                store.duplicateProject(id: id)
                onDismiss()
            }
            .disabled(store.activeProjectID == nil)

            divider

            action(title: "导入项目 / 工作区…", symbol: "square.and.arrow.down") {
                onDismiss()
                guard let url = FileDialogs.openJSON(message: "选择 wac 工作区文件（多项目）或单个项目 JSON") else { return }
                store.importProjects(from: url)
            }
            divider

            action(title: "导出当前项目…", symbol: "square.and.arrow.up") {
                guard let project = store.activeProject else { return }
                onDismiss()
                guard let url = FileDialogs.saveJSON(defaultName: "\(project.name).json") else { return }
                store.exportProject(id: project.id, to: url)
            }
            .disabled(store.activeProjectID == nil)

            divider

            action(title: "删除当前项目", symbol: "trash", destructive: true) {
                guard let project = store.activeProject else { return }
                onDismiss()
                ui.askDelete(
                    title: "删除项目「\(project.name)」？",
                    message: "将删除该项目下的 \(project.requests.count) 个接口、环境变量与相关标签页，且不可撤销。"
                ) {
                    store.deleteProject(id: project.id)
                }
            }
            .disabled(store.activeProjectID == nil)
        }
        .padding(DS.space.sm)
        .frame(width: 272)
        .background(DS.color.surface)
    }

    // MARK: 行

    private func projectRow(_ project: Project) -> some View {
        let isActive = project.id == store.activeProjectID
        // 标签按项目隔离，切走以后标签不会消失，这里给个数量提示它们在哪。
        let openTabs = store.openTabCount(projectID: project.id)

        return Button {
            store.setActiveProject(id: project.id)
            onDismiss()
        } label: {
            HStack(spacing: DS.space.md) {
                Circle()
                    .fill(isActive ? DS.color.brand : DS.color.textTertiary.opacity(0.35))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 0) {
                    Text(project.name)
                        .font(isActive ? DS.font.bodyMedium : DS.font.body)
                        .foregroundStyle(DS.color.textPrimary)
                        .lineLimit(1)
                    Text("\(project.requests.count) 个接口 · \(project.environments.count) 个环境")
                        .font(DS.font.micro)
                        .foregroundStyle(DS.color.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: DS.space.md)

                if openTabs > 0 {
                    Text("\(openTabs) 个标签")
                        .font(DS.font.micro)
                        .foregroundStyle(DS.color.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DS.color.field, in: Capsule())
                        .help("该项目打开的标签（切过去即可回到原处）")
                }

                if isActive {
                    AppIcon(symbol: "checkmark", size: 10, weight: .bold, tint: DS.color.brand)
                }
            }
            .padding(.horizontal, DS.space.md)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(isSelected: isActive, horizontalInset: 0)
    }

    private func action(
        title: String,
        symbol: String,
        destructive: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: DS.space.md) {
                AppIcon(
                    symbol: symbol,
                    size: 11,
                    tint: destructive ? DS.color.danger : DS.color.textSecondary
                )
                .frame(width: 14)
                Text(title)
                    .font(DS.font.body)
                    .foregroundStyle(destructive ? DS.color.danger : DS.color.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.space.md)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(horizontalInset: 0)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(DS.font.micro)
            .foregroundStyle(DS.color.textTertiary)
            .padding(.horizontal, DS.space.md)
            .padding(.top, DS.space.sm)
            .padding(.bottom, DS.space.xs)
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
            .padding(.vertical, DS.space.xs)
    }
}
