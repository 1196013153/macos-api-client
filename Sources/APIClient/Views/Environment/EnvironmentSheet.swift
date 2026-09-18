import SwiftUI
import ApiClientCore

/// 环境 / 全局变量 / 全局请求头管理。
struct EnvironmentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let projectID: UUID

    @State private var selection: Selection = .globals
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case name
        case baseURL
    }

    enum Selection: Hashable {
        case environment(UUID)
        case globals
        case globalHeaders
    }

    private var project: Project? { store.project(id: projectID) }

    private var selectedEnvironment: APIEnvironment? {
        guard case .environment(let id) = selection else { return nil }
        return project?.environment(id: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            HStack(spacing: 0) {
                environmentList
                    .frame(width: 226)
                verticalHairline
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 960, height: 640)
        .background(DS.color.canvas)
        .onAppear(perform: selectInitial)
    }

    private var hairline: some View {
        Rectangle().fill(DS.color.hairline).frame(height: 1)
    }

    private var verticalHairline: some View {
        Rectangle().fill(DS.color.hairline).frame(width: 1)
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: DS.space.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                    .fill(DS.color.brandSoft)
                    .frame(width: 28, height: 28)
                AppIcon(symbol: "globe", size: 13, tint: DS.color.brand)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("环境与变量")
                    .font(DS.font.title)
                    .foregroundStyle(DS.color.textPrimary)
                Text("变量优先级：运行时 > 环境变量 > 项目全局变量 > 内置动态变量")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
            }

            Spacer(minLength: 0)

            Button("完成") { dismiss() }
                .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, DS.space.xl)
        .frame(height: DS.metric.headerHeight + 8)
        .background(DS.color.surface)
    }

    // MARK: 左侧列表

    private var environmentList: some View {
        VStack(spacing: 0) {
            List(selection: Binding<Selection?>(
                get: { selection },
                set: { newValue in if let newValue { selection = newValue } }
            )) {
                Section("环境") {
                    ForEach(project?.environments ?? []) { environment in
                        environmentRow(environment)
                    }
                }

                Section("项目级") {
                    Label("全局变量", systemImage: "shippingbox")
                        .tag(Selection.globals)
                    Label("全局请求头", systemImage: "list.bullet.rectangle")
                        .tag(Selection.globalHeaders)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            hairline
            addBar
        }
        .background(DS.color.surface)
    }

    /// 单独抽出来，避免 List 的 ViewBuilder 嵌套过深导致类型检查超时。
    private func environmentRow(_ environment: APIEnvironment) -> some View {
        let isActive = environment.id == project?.activeEnvironment?.id
        return HStack(spacing: DS.space.sm) {
            Circle()
                .fill(isActive ? DS.color.success : DS.color.textTertiary.opacity(0.35))
                .frame(width: 6, height: 6)
            Text(environment.name)
                .font(DS.font.body)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .tag(Selection.environment(environment.id))
        .contextMenu {
            Button("设为当前环境") {
                store.setActiveEnvironment(projectID: projectID, environmentID: environment.id)
            }
            Button("删除环境", role: .destructive) {
                store.deleteEnvironment(projectID: projectID, environmentID: environment.id)
                selection = .globals
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: DS.space.sm) {
            Button {
                let name = "环境 \((project?.environments.count ?? 0) + 1)"
                if let id = store.addEnvironment(projectID: projectID, name: name, baseURL: "") {
                    selection = .environment(id)
                }
            } label: {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "plus", size: 9, weight: .bold, tint: DS.color.brand)
                    Text("新建环境")
                        .font(DS.font.caption)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))

            Spacer(minLength: 0)

            Text("\(project?.environments.count ?? 0) 个环境")
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
        }
        .padding(.horizontal, DS.space.md)
        .frame(height: 40)
    }

    // MARK: 右侧详情

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .environment:
            if let environment = selectedEnvironment {
                environmentDetail(environment)
            } else {
                EmptyState(art: .search, title: "环境不存在")
            }
        case .globals:
            variableEditor(
                title: "项目全局变量",
                subtitle: "所有环境共享，环境变量会覆盖同名项。URL、参数、请求头里都能用 {{变量名}} 引用。",
                art: "shippingbox",
                items: Binding(
                    get: { project?.globals ?? [] },
                    set: { newValue in store.updateProject(id: projectID) { $0.globals = newValue } }
                )
            )
        case .globalHeaders:
            variableEditor(
                title: "项目全局请求头",
                subtitle: "项目下所有请求自动携带，请求内的同名 Header 会覆盖这里。值支持 {{变量}}。",
                art: "list.bullet.rectangle",
                items: Binding(
                    get: { project?.globalHeaders ?? [] },
                    set: { newValue in store.updateProject(id: projectID) { $0.globalHeaders = newValue } }
                )
            )
        }
    }

    private func environmentDetail(_ environment: APIEnvironment) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.space.lg) {
                HStack(spacing: DS.space.xl) {
                    labeledField("环境名称", width: 96) {
                        TextField("环境名称", text: stringBinding(\.name))
                            .fieldChrome(isFocused: focusedField == .name, height: 26)
                            .focused($focusedField, equals: .name)
                    }

                    Spacer(minLength: 0)

                    if environment.id == project?.activeEnvironment?.id {
                        HStack(spacing: DS.space.xs) {
                            AppIcon(symbol: "checkmark.circle.fill", size: 11, tint: DS.color.success)
                            Text("正在使用")
                                .font(DS.font.caption)
                                .foregroundStyle(DS.color.success)
                        }
                        .padding(.horizontal, DS.space.md)
                        .padding(.vertical, 2)
                        .background(DS.color.successSoft, in: Capsule())
                    } else {
                        Button("设为当前环境") {
                            store.setActiveEnvironment(projectID: projectID, environmentID: environment.id)
                        }
                        .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
                    }
                }

                labeledField("baseURL", width: 96) {
                    TextField("例如 https://api.example.com/test1/demo-api", text: stringBinding(\.baseURL))
                        .fieldChrome(isFocused: focusedField == .baseURL, height: 26, monospaced: true)
                        .focused($focusedField, equals: .baseURL)
                }

                HStack(spacing: DS.space.sm) {
                    AppIcon(symbol: "info.circle.fill", size: 10, tint: DS.color.brand)
                    Text("相对路径的请求会自动拼上 baseURL；也可以在地址里直接写 {{baseUrl}}。")
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textSecondary)
                }
                .padding(.horizontal, DS.space.lg)
                .padding(.vertical, DS.space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.color.brandSoft, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
            }
            .padding(DS.space.xl)

            hairline

            KeyValueTableEditor(
                items: binding(\.variables),
                keyPlaceholder: "变量名",
                valuePlaceholder: "变量值",
                addTitle: "添加变量",
                emptyTitle: "这个环境还没有变量"
            )
        }
    }

    private func variableEditor(
        title: String,
        subtitle: String,
        art: String,
        items: Binding<[KeyValueItem]>
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DS.space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                        .fill(DS.color.brandSoft)
                        .frame(width: 28, height: 28)
                    AppIcon(symbol: art, size: 13, tint: DS.color.brand)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.font.heading)
                        .foregroundStyle(DS.color.textPrimary)
                    Text(subtitle)
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(DS.space.xl)

            hairline

            KeyValueTableEditor(
                items: items,
                keyPlaceholder: "变量名",
                valuePlaceholder: "变量值",
                addTitle: "添加变量",
                emptyTitle: "还没有变量"
            )
        }
    }

    private func labeledField<Content: View>(
        _ title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: DS.space.md) {
            Text(title)
                .font(DS.font.captionMedium)
                .foregroundStyle(DS.color.textSecondary)
                .frame(width: width, alignment: .leading)
            content()
        }
    }

    // MARK: 绑定

    private func stringBinding(_ keyPath: WritableKeyPath<APIEnvironment, String>) -> Binding<String> {
        Binding(
            get: { selectedEnvironment?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard let environmentID = selectedEnvironment?.id else { return }
                store.updateProject(id: projectID) { project in
                    guard let index = project.environments.firstIndex(where: { $0.id == environmentID }) else { return }
                    project.environments[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func binding(_ keyPath: WritableKeyPath<APIEnvironment, [KeyValueItem]>) -> Binding<[KeyValueItem]> {
        Binding(
            get: { selectedEnvironment?[keyPath: keyPath] ?? [] },
            set: { newValue in
                guard let environmentID = selectedEnvironment?.id else { return }
                store.updateProject(id: projectID) { project in
                    guard let index = project.environments.firstIndex(where: { $0.id == environmentID }) else { return }
                    project.environments[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func selectInitial() {
        if let active = project?.activeEnvironment?.id {
            selection = .environment(active)
        } else {
            selection = .globals
        }
    }
}
