import AppKit
import SwiftUI
import ApiClientCore

struct RequestEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let session: TabSession

    @FocusState private var isURLFocused: Bool
    @FocusState private var isNameFocused: Bool

    private var project: Project? { store.project(id: session.projectID) }

    /// 停在哪个分区由标签自己记（切标签、切项目回来还是原来那一栏）。
    private var pane: Binding<RequestPane> {
        Binding(
            get: { session.activePane },
            set: { session.activePane = $0 }
        )
    }

    /// 这次发送会不会走 Mock。
    private var isMocking: Bool { store.settings.shouldMock(session.buffer) }

    var body: some View {
        VStack(spacing: 0) {
            urlBar
            hairline
            metaBar
            hairline
            SectionTabBar(
                items: RequestPane.allCases,
                title: { $0.title },
                badge: { badge(for: $0) },
                accent: { accent(for: $0) },
                selection: pane
            )
            .background(DS.color.surface)

            hairline

            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.color.sunken)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
    }

    // MARK: 地址栏

    private var urlBar: some View {
        HStack(spacing: DS.space.md) {
            methodMenu

            TextField("输入请求地址，支持 {{变量}} 与 /api/user/:id 路径参数", text: urlBinding)
                .fieldChrome(isFocused: isURLFocused, height: 30, monospaced: true)
                .focused($isURLFocused)
                .onSubmit { send() }

            sendButton
        }
        .padding(.horizontal, DS.space.lg)
        .padding(.vertical, DS.space.md)
        .background(DS.color.surface)
    }

    private var methodMenu: some View {
        Menu {
            ForEach(HTTPMethod.allCases) { method in
                Button {
                    store.updateBuffer(tabID: session.id) { $0.method = method }
                } label: {
                    Text(method.rawValue)
                }
            }
        } label: {
            HoverChip(isActive: true, accent: session.buffer.method.tint, height: 30) {
                HStack(spacing: DS.space.xs) {
                    Text(session.buffer.method.rawValue)
                        .font(DS.font.methodPicker)
                        .foregroundStyle(session.buffer.method.tint)
                    AppIcon(symbol: "chevron.down", size: 8, weight: .bold, tint: session.buffer.method.tint)
                }
                .frame(width: 76)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("请求方法")
        .animation(DS.motion.select, value: session.buffer.method)
    }

    private var sendButton: some View {
        Button(action: sendOrCancel) {
            HStack(spacing: DS.space.sm) {
                if session.isSending {
                    SpinnerDot(color: .white, size: 11)
                    Text("取消")
                } else {
                    AppIcon(symbol: "paperplane.fill", size: 10, weight: .semibold, tint: .white)
                    Text("发送")
                    if isMocking {
                        Text("MOCK")
                            .font(DS.font.badgeSmall)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.22), in: Capsule())
                    }
                }
            }
            .frame(minWidth: 78)
        }
        .buttonStyle(
            AppButtonStyle(
                kind: .prominent,
                size: .regular,
                tint: session.isSending ? DS.color.danger : nil,
                height: 30
            )
        )
        .keyboardShortcut(.return, modifiers: .command)
        .help(
            session.isSending
                ? "取消请求（⌘.）"
                : (isMocking ? "发送（⌘↵）—— 该接口开着 Mock，不会发出真实网络请求" : "发送请求（⌘↵）")
        )
        .animation(DS.motion.select, value: session.isSending)
    }

    // MARK: 收藏

    private var isCurrentFavorite: Bool {
        guard let requestID = session.requestID else { return false }
        return store.isFavorite(projectID: session.projectID, requestID: requestID)
    }

    /// 名称旁的星标：正式接口可一键收藏 / 取消；草稿先保存才有资格收藏。
    private var favoriteToggle: some View {
        Button {
            guard let requestID = session.requestID else { return }
            store.toggleFavorite(projectID: session.projectID, requestID: requestID)
        } label: {
            AppIcon(
                symbol: isCurrentFavorite ? "star.fill" : "star",
                size: 11,
                tint: isCurrentFavorite ? DS.color.warning : DS.color.textTertiary
            )
        }
        .buttonStyle(
            IconButtonStyle(
                size: 22,
                tint: isCurrentFavorite ? DS.color.warning : DS.color.textTertiary,
                hoverTint: DS.color.warning
            )
        )
        .disabled(session.isDraft)
        .help(
            session.isDraft
                ? "保存为正式接口后才能收藏"
                : (isCurrentFavorite ? "取消收藏" : "收藏，置顶到侧边栏「收藏」区")
        )
        .animation(DS.motion.select, value: isCurrentFavorite)
    }

    // MARK: 操作栏

    private var metaBar: some View {
        HStack(spacing: DS.space.md) {
            AppIcon(
                symbol: session.isDraft ? "doc.badge.plus" : "doc.text",
                size: 10,
                tint: DS.color.textTertiary
            )

            TextField("请求名称", text: nameBinding)
                .fieldChrome(isFocused: isNameFocused, height: 24, horizontalPadding: DS.space.sm)
                .focused($isNameFocused)
                .frame(width: 176)

            favoriteToggle

            if session.isDraft || session.isDirty {
                Text(session.isDraft ? "草稿" : "未保存")
                    .font(DS.font.micro)
                    .foregroundStyle(DS.color.warning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(DS.color.warningSoft, in: Capsule())
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }

            Spacer(minLength: DS.space.md)

            previewChip

            mockChip

            if let project {
                environmentMenu(project: project)
            }

            Button("保存") { _ = store.saveTab(tabID: session.id) }
                .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
                .disabled(!session.isDirty)
                .help("保存当前标签（⌘S）")

            moreMenu
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: DS.metric.barHeight)
        .background(DS.color.surface)
        .animation(DS.motion.select, value: session.isDirty)
    }

    /// 常驻的 Mock 开关：不切到 Mock 分区也能一眼看到当前状态、一键切换。
    private var mockChip: some View {
        Button(action: toggleMock) {
            HoverChip(isActive: isMocking, accent: DS.color.brand) {
                HStack(spacing: DS.space.xs) {
                    AppIcon(
                        symbol: "wand.and.rays",
                        size: 10,
                        tint: isMocking ? DS.color.brand : DS.color.textTertiary
                    )
                    Text(mockLabel)
                        .font(DS.font.captionMedium)
                        .foregroundStyle(isMocking ? DS.color.brand : DS.color.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(mockHelp)
        .animation(DS.motion.select, value: isMocking)
    }

    private var mockLabel: String {
        switch store.settings.mockMode {
        case .off: return "Mock 关闭"
        case .always: return "Mock 全量"
        case .perRequest: return session.buffer.mock.isEnabled ? "Mock 开" : "Mock"
        }
    }

    private var mockHelp: String {
        switch store.settings.mockMode {
        case .off:
            return "Mock 已在设置中关闭，接口开关不生效；点这里去设置里改"
        case .always:
            return "当前是「全量 Mock」：所有请求都返回模拟数据；点这里去设置里改"
        case .perRequest:
            return session.buffer.mock.isEnabled
                ? "该接口当前返回 Mock 数据（不发真实网络），点击改为真实请求"
                : "打开后该接口返回 Mock 数据，后端没就绪也能联调"
        }
    }

    private func toggleMock() {
        switch store.settings.mockMode {
        case .off:
            store.setNotice("Mock 已在设置里关闭，可在「设置 → Mock」改为「按接口」", level: .error)
        case .always:
            ui.sheet = .settings
        case .perRequest:
            let next = !session.buffer.mock.isEnabled
            store.updateBuffer(tabID: session.id) { $0.mock.isEnabled = next }
            store.setNotice(next ? "「\(session.displayName)」改为 Mock 返回" : "「\(session.displayName)」恢复真实请求")
        }
    }

    @ViewBuilder
    private var previewChip: some View {
        if let resolved = store.previewURL(for: session), resolved.url != session.buffer.url {
            let hasUnresolved = !resolved.unresolved.isEmpty
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resolved.url, forType: .string)
                store.setNotice("已复制实际请求地址")
            } label: {
                HoverChip(isActive: hasUnresolved, accent: DS.color.warning, height: 24) {
                    HStack(spacing: DS.space.xs) {
                        AppIcon(
                            symbol: hasUnresolved ? "exclamationmark.triangle" : "arrow.turn.down.right",
                            size: 9,
                            tint: hasUnresolved ? DS.color.warning : DS.color.textTertiary
                        )
                        Text(resolved.url)
                            .font(DS.font.monoSmall)
                            .foregroundStyle(hasUnresolved ? DS.color.warning : DS.color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: 300, alignment: .trailing)
                }
            }
            .buttonStyle(.plain)
            .help(
                hasUnresolved
                    ? "存在未解析变量：\(resolved.unresolved.joined(separator: "、"))"
                    : "实际发出的地址，点击复制"
            )
        }
    }

    private func environmentMenu(project: Project) -> some View {        Menu {
            Section("环境") {
                ForEach(project.environments) { environment in
                    Button {
                        store.setActiveEnvironment(projectID: project.id, environmentID: environment.id)
                    } label: {
                        if environment.id == project.activeEnvironment?.id {
                            Label(environment.name, systemImage: "checkmark")
                        } else {
                            Text(environment.name)
                        }
                    }
                }
            }
            Divider()
            Button("管理环境与变量…") { ui.sheet = .environment(project.id) }
        } label: {
            HoverChip {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "globe", size: 10, tint: DS.color.textSecondary)
                    Text(project.activeEnvironment?.name ?? "未选择环境")
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textPrimary)
                        .lineLimit(1)
                    AppIcon(symbol: "chevron.down", size: 7, weight: .bold, tint: DS.color.textTertiary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(
            project.activeEnvironment?.baseURL.isEmpty == false
                ? "baseURL: \(project.activeEnvironment?.baseURL ?? "")"
                : "该环境未设置 baseURL"
        )
    }

    private var moreMenu: some View {
        Menu {
            if let requestID = session.requestID {
                Button("在侧边栏中定位") {
                    store.locateInSidebar(projectID: session.projectID, requestID: requestID)
                }
                Divider()
            }
            Button("另存为新接口") { _ = store.saveTab(tabID: session.id, asNew: true) }
            Button("复制为 cURL") { copyCurl() }
            Button("复制地址") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.buffer.url, forType: .string)
            }
            Divider()
            Button("丢弃未保存修改") { store.revertBuffer(tabID: session.id) }
                .disabled(!session.isDirty || session.isDraft)
            if let requestID = session.requestID, let project {
                Button("删除该接口", role: .destructive) {
                    guard let nodeID = project.collection.nodeID(forRequest: requestID) else { return }
                    ui.askDelete(title: "删除「\(session.buffer.name)」？", message: "删除后不可撤销。") {
                        store.deleteNode(projectID: project.id, nodeID: nodeID)
                    }
                }
            }
        } label: {
            AppIcon(symbol: "ellipsis.circle", size: 14, tint: DS.color.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("更多操作")
    }

    // MARK: 分区内容

    @ViewBuilder
    private var sectionContent: some View {
        switch session.activePane {
        case .params:
            KeyValueTableEditor(
                items: itemsBinding(\.params),
                showsLocation: true,
                keyPlaceholder: "参数名",
                valuePlaceholder: "参数值",
                addTitle: "添加参数",
                emptyTitle: "还没有参数"
            )
        case .headers:
            VStack(spacing: 0) {
                if let inherited = inheritedHeaderHint {
                    HStack(spacing: DS.space.sm) {
                        AppIcon(symbol: "info.circle.fill", size: 10, tint: DS.color.brand)
                        Text(inherited)
                            .font(DS.font.caption)
                            .foregroundStyle(DS.color.textSecondary)
                            .lineLimit(2)
                        Spacer(minLength: DS.space.md)
                        Button("管理") {
                            if let project { ui.sheet = .environment(project.id) }
                        }
                        .buttonStyle(AppButtonStyle(kind: .ghost, size: .small))
                    }
                    .padding(.horizontal, DS.space.lg)
                    .padding(.vertical, DS.space.sm)
                    .background(DS.color.brandSoft)
                    hairline
                }
                KeyValueTableEditor(
                    items: itemsBinding(\.headers),
                    keyPlaceholder: "Header 名",
                    valuePlaceholder: "Header 值",
                    addTitle: "添加请求头",
                    emptyTitle: "还没有请求头"
                )
            }
        case .body:
            RequestBodyEditor(session: session)
        case .mock:
            MockEditorView(session: session)
        case .note:
            noteEditor
        }
    }

    private var noteEditor: some View {
        TextEditor(text: noteBinding)
            .font(DS.font.body)
            .scrollContentBackground(.hidden)
            .padding(DS.space.md)
            .background(DS.color.sunken)
            .overlay(alignment: .topLeading) {
                if session.buffer.note.isEmpty {
                    Text("备注、字段说明、依赖条件…")
                        .font(DS.font.body)
                        .foregroundStyle(DS.color.textTertiary)
                        .padding(.horizontal, DS.space.lg)
                        .padding(.vertical, DS.space.lg)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: 绑定

    private var urlBinding: Binding<String> { bufferBinding(\.url) }
    private var nameBinding: Binding<String> { bufferBinding(\.name) }
    private var noteBinding: Binding<String> { bufferBinding(\.note) }

    private func bufferBinding(_ keyPath: WritableKeyPath<APIRequest, String>) -> Binding<String> {
        Binding(
            get: { session.buffer[keyPath: keyPath] },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// 数组字段的绑定：所有写入都经过 AppStore，保证脏标记与落盘调度不被绕过。
    private func itemsBinding(_ keyPath: WritableKeyPath<APIRequest, [KeyValueItem]>) -> Binding<[KeyValueItem]> {
        Binding(
            get: { session.buffer[keyPath: keyPath] },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    // MARK: 动作

    private func sendOrCancel() {
        if session.isSending {
            store.cancelSend(tabID: session.id)
        } else {
            store.send(tabID: session.id)
        }
    }

    private func send() {
        guard !session.isSending else { return }
        store.send(tabID: session.id)
    }

    private func copyCurl() {
        guard let project else { return }
        do {
            let resolved = try RequestBuilder.resolve(
                request: session.buffer,
                project: project,
                environment: project.activeEnvironment,
                runtimeVariables: store.runtimeVariables
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(RequestBuilder.curlCommand(for: resolved), forType: .string)
            store.setNotice("已复制 cURL 到剪贴板")
        } catch {
            store.setNotice("生成 cURL 失败：\(error.localizedDescription)", level: .error)
        }
    }

    // MARK: 分区徽标

    private func badge(for pane: RequestPane) -> String? {
        switch pane {
        case .params:
            let count = session.buffer.params.activeItems.count
            return count > 0 ? "\(count)" : nil
        case .headers:
            let count = session.buffer.headers.activeItems.count
            return count > 0 ? "\(count)" : nil
        case .body:
            return session.buffer.body.kind == .none ? nil : session.buffer.body.kind.title
        case .mock:
            switch store.settings.mockMode {
            case .always: return "全量"
            case .off: return nil
            case .perRequest: return session.buffer.mock.isEnabled ? "开" : nil
            }
        case .note:
            return session.buffer.note.isEmpty ? nil : "有"
        }
    }

    /// 分区指示条颜色：请求体按内容类型区分，"这个请求发的是 JSON 还是表单"一眼可见。
    private func accent(for pane: RequestPane) -> Color? {
        switch pane {
        case .body:
            return session.buffer.body.kind.accent
        case .mock:
            return isMocking ? DS.color.brand : nil
        default:
            return nil
        }
    }

    private var inheritedHeaderHint: String? {
        guard let project, !project.globalHeaders.activeItems.isEmpty else { return nil }
        let names = project.globalHeaders.activeItems.compactMap(\.activeKey).joined(separator: "、")
        return "该项目所有请求会自动携带全局请求头：\(names)（同名项会被下方覆盖）"
    }
}
