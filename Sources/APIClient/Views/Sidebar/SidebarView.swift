import AppKit
import SwiftUI
import ApiClientCore

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui
    @State private var showProjectMenu = false
    @State private var favoritesExpanded = true
    /// 搜索框的本地输入。每个字符都直接写进 store 会让上千接口的搜索跟着每次按键同步跑，
    /// 这里先落在本地，停顿一下再提交到 `store.sidebarFilter`。
    @State private var searchText = ""
    @State private var searchCommitTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    /// 搜索结果里的键盘光标（↑↓ 移动、⏎ 打开）。结果变了就回到第一条。
    @State private var highlightedResult = 0

    var body: some View {
        VStack(spacing: 0) {
            projectSwitcher
            hairline
            searchBar
            hairline
            collectionTree
            hairline
            footer
        }
        .background(DS.color.surface)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
    }

    // MARK: 项目切换器

    private var projectSwitcher: some View {
        Button {
            showProjectMenu = true
        } label: {
            HStack(spacing: DS.space.md) {
                BrandMark()

                VStack(alignment: .leading, spacing: 0) {
                    Text(store.activeProject?.name ?? "未选择项目")
                        .font(DS.font.heading)
                        .foregroundStyle(DS.color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(projectSubtitle)
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: DS.space.sm)

                AppIcon(symbol: "chevron.up.chevron.down", size: 9, weight: .semibold, tint: DS.color.textTertiary)
            }
            .padding(.horizontal, DS.space.lg)
            .frame(maxWidth: .infinity)
            .frame(height: DS.metric.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHighlight(cornerRadius: 0, horizontalInset: 0)
        .popover(isPresented: $showProjectMenu, arrowEdge: .bottom) {
            ProjectMenu(onDismiss: { showProjectMenu = false })
                .environment(store)
                .environment(ui)
        }
        .help("切换 / 管理项目")
    }

    private var projectSubtitle: String {
        guard let project = store.activeProject else { return "点击新建项目" }
        let environment = project.activeEnvironment?.name ?? "未选择环境"
        return "\(project.requests.count) 个接口 · \(environment)"
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: DS.space.sm) {
            HStack(spacing: DS.space.sm) {
                AppIcon(symbol: "magnifyingglass", size: 11, tint: DS.color.textTertiary)

                TextField("搜索接口（⌘K）", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.font.body)
                    .focused($isSearchFocused)
                    .onAppear { searchText = store.sidebarFilter }
                    .onChange(of: searchText) { _, newValue in scheduleSearchCommit(newValue) }
                    .onChange(of: store.sidebarFilter) { _, newValue in
                        // 切项目 / 定位等外部清空搜索词时，输入框跟着同步
                        if searchText != newValue { searchText = newValue }
                        highlightedResult = 0
                    }
                    .onChange(of: ui.searchFocusTicket) { _, _ in isSearchFocused = true }
                    .onSubmit { openHighlightedResult() }
                    .onKeyPress(.downArrow) { moveHighlight(1) }
                    .onKeyPress(.upArrow) { moveHighlight(-1) }
                    .onKeyPress(.escape) {
                        clearSearch()
                        isSearchFocused = false
                        return .handled
                    }

                if !searchText.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
                        AppIcon(symbol: "xmark.circle.fill", size: 11, tint: DS.color.textTertiary)
                    }
                    .buttonStyle(IconButtonStyle(size: 16, tint: DS.color.textTertiary))
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .padding(.horizontal, DS.space.md)
            .frame(height: 26)
            .background(DS.color.field, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                    .strokeBorder(DS.color.hairline)
            )
            .animation(DS.motion.hover, value: searchText.isEmpty)

            if let projectID = store.activeProjectID {
                Menu {
                    Button("全部展开") { store.setAllFolders(projectID: projectID, expanded: true) }
                    Button("全部折叠") { store.setAllFolders(projectID: projectID, expanded: false) }
                } label: {
                    AppIcon(symbol: "chevron.up.chevron.down", size: 10, weight: .semibold, tint: DS.color.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("展开 / 折叠所有目录")
            }
        }
        .padding(.horizontal, DS.space.md)
        .padding(.vertical, DS.space.sm)
    }

    // MARK: 集合树

    @ViewBuilder
    private var collectionTree: some View {
        if store.activeProject == nil {
            EmptyState(
                art: .collection,
                title: "还没有项目",
                subtitle: "点击上方的项目名称新建一个",
                actionTitle: "新建项目",
                action: { promptNewProject() }
            )
        } else if hasSearchQuery {
            searchResults
        } else if store.sidebarRows.isEmpty {
            EmptyState(
                art: .collection,
                title: "这个项目还没有接口",
                subtitle: "右键空白处新建请求，或按 ⌘T",
                actionTitle: "新建请求",
                action: { createRootRequest() }
            )
        } else {
            // 选中 / 收藏状态在这里算好传给行：行视图不读 store，切标签、收藏时只有状态变了的行才会刷新。
            let currentRequestID = store.activeSession?.requestID
            let favoriteIDs = Set(store.sidebarFavorites.map(\.id))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !store.sidebarFavorites.isEmpty {
                            favoritesSection(currentRequestID: currentRequestID)
                        }
                        ForEach(store.sidebarRows) { row in
                            SidebarRowView(
                                row: row,
                                isSelected: row.node.requestID != nil && row.node.requestID == currentRequestID,
                                isFavorite: row.node.requestID.map { favoriteIDs.contains($0) } ?? false
                            )
                            .id(row.id)
                        }
                    }
                    .padding(.vertical, DS.space.xs)
                }
                .onChange(of: store.sidebarRevealTicket) { _, _ in scrollToCurrentRequest(proxy) }
                .onAppear { scrollToCurrentRequest(proxy) }
            }
            .contextMenu {
                if let projectID = store.activeProjectID {
                    Button("新建请求") { createRootRequest() }
                    Button("新建文件夹") {
                        store.addFolder(projectID: projectID, parentID: nil)
                    }
                    Divider()
                    Button("全部展开") { store.setAllFolders(projectID: projectID, expanded: true) }
                    Button("全部折叠") { store.setAllFolders(projectID: projectID, expanded: false) }
                }
            }
        }
    }

    // MARK: 搜索结果

    private var hasSearchQuery: Bool {
        !store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 搜索模式：平铺、按相关度排序的结果列表，替代「收藏区 + 树」。
    /// 匹配范围覆盖名称 / URL / 完整 URL / 备注 / 方法，支持子序列模糊命中。
    @ViewBuilder
    private var searchResults: some View {
        if store.sidebarSearchResults.isEmpty {
            EmptyState(
                art: .search,
                title: "没有匹配的接口",
                subtitle: "支持按名称、URL、备注、方法搜索，可以模糊匹配"
            )
        } else {
            let currentRequestID = store.activeSession?.requestID
            let favoriteIDs = Set(store.sidebarFavorites.map(\.id))
            let query = store.sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DS.space.sm) {
                        AppIcon(symbol: "magnifyingglass", size: 9, tint: DS.color.textTertiary)
                        Text("搜索到 \(store.sidebarSearchResults.count) 个接口")
                            .font(DS.font.micro)
                            .foregroundStyle(DS.color.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.space.md)
                    .frame(height: 24)

                    ForEach(Array(store.sidebarSearchResults.enumerated()), id: \.element.id) { offset, result in
                        SearchResultRow(
                            result: result,
                            query: query,
                            isSelected: result.request.id == currentRequestID,
                            isFavorite: favoriteIDs.contains(result.request.id),
                            isHighlighted: isSearchFocused && offset == highlightedResult
                        )
                    }
                }
                .padding(.vertical, DS.space.xs)
            }
        }
    }

    // MARK: 收藏区

    /// 收藏的接口置顶展示：与集合树同一滚动容器，空时不占位。
    /// 点击行 = 打开接口（不在树里定位，树保持原样），点行尾金星 = 取消收藏。
    private func favoritesSection(currentRequestID: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.motion.select) { favoritesExpanded.toggle() }
            } label: {
                HStack(spacing: DS.space.sm) {
                    AppIcon(symbol: "star.fill", size: 9, tint: DS.color.warning)
                    Text("收藏")
                        .font(DS.font.micro)
                        .foregroundStyle(DS.color.textSecondary)
                    Text("\(store.sidebarFavorites.count)")
                        .font(DS.font.micro)
                        .foregroundStyle(DS.color.textTertiary)
                    Spacer(minLength: 0)
                    AppIcon(symbol: "chevron.right", size: 7, weight: .bold, tint: DS.color.textTertiary)
                        .rotationEffect(.degrees(favoritesExpanded ? 90 : 0))
                }
                .padding(.horizontal, DS.space.md)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if favoritesExpanded {
                ForEach(store.sidebarFavorites) { request in
                    FavoriteRowView(request: request, isSelected: request.id == currentRequestID)
                }
            }

            Rectangle()
                .fill(DS.color.hairline)
                .frame(height: 1)
                .padding(.top, DS.space.xs)
                .padding(.bottom, DS.space.hair)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: DS.space.sm) {
            AppIcon(symbol: "internaldrive", size: 10, tint: DS.color.textTertiary)
            Text("\(store.projects.count) 个项目 · \(store.totalRequestCount) 个接口")
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
            Spacer(minLength: 0)

            Button {
                store.flushSave()
                NSWorkspace.shared.open(URL(fileURLWithPath: store.storageRootPath))
            } label: {
                AppIcon(symbol: "folder", size: 10, tint: DS.color.textTertiary)
            }
            .buttonStyle(IconButtonStyle(size: 20, tint: DS.color.textTertiary))
            .help("在访达中打开数据目录")
        }
        .padding(.horizontal, DS.space.md)
        .frame(height: 28)
    }

    // MARK: 动作

    /// 把当前标签对应的接口滚进视野。只在 `revealRequest` 触发时做：
    /// `LazyVStack` 里滚到远处的行要先把途中所有行都建出来，对上千行的树是最贵的一步。
    /// 不带动画：动画会让途中每一行分摊到各帧里逐个建出来，总耗时翻倍且一路掉帧，直接跳过去更顺。
    /// 搜索过滤时行可能不存在，静默跳过即可。
    private func scrollToCurrentRequest(_ proxy: ScrollViewProxy) {
        guard let requestID = store.activeSession?.requestID,
              let row = store.sidebarRows.first(where: { $0.node.requestID == requestID }) else { return }
        proxy.scrollTo(row.id, anchor: .center)
    }

    private func scheduleSearchCommit(_ text: String) {
        searchCommitTask?.cancel()
        guard text != store.sidebarFilter else { return }
        searchCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            store.sidebarFilter = text
        }
    }

    private func clearSearch() {
        searchCommitTask?.cancel()
        searchText = ""
        store.sidebarFilter = ""
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        let count = store.sidebarSearchResults.count
        guard count > 0 else { return .ignored }
        highlightedResult = (highlightedResult + delta + count) % count
        return .handled
    }

    /// ⏎ 打开光标所在的结果；搜索词还没提交（防抖中）就先提交再打开。
    private func openHighlightedResult() {
        searchCommitTask?.cancel()
        if searchText != store.sidebarFilter { store.sidebarFilter = searchText }
        let results = store.sidebarSearchResults
        guard let projectID = store.activeProjectID, !results.isEmpty else { return }
        let index = min(highlightedResult, results.count - 1)
        store.openRequest(projectID: projectID, requestID: results[index].request.id)
    }

    private func createRootRequest() {
        guard let projectID = store.activeProjectID else { return }
        if let requestID = store.addRequest(projectID: projectID, folderID: nil) {
            store.openRequest(projectID: projectID, requestID: requestID)
        }
    }

    private func promptNewProject() {
        ui.ask(title: "新建项目", placeholder: "项目名称", confirmTitle: "创建") { name in
            store.createProject(name: name)
        }
    }

}

// MARK: - 树节点行

struct SidebarRowView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let row: TreeRow
    /// 选中 / 收藏由父视图算好传入：body 里不读 store，父视图刷新时值没变的行会被 SwiftUI 跳过。
    let isSelected: Bool
    let isFavorite: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: handleTap) {
                HStack(spacing: DS.space.sm) {
                    indentGuides
                    disclosure
                    content
                    Spacer(minLength: 0)
                }
                .padding(.leading, DS.space.md)
                .frame(height: DS.metric.listRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle(scale: 0.99))

            // 行尾固定宽度的星标位：文件夹与请求行的右缘保持对齐
            Group {
                if !row.isFolder {
                    if isFavorite {
                        Button(action: toggleFavorite) {
                            AppIcon(symbol: "star.fill", size: 10, tint: DS.color.warning)
                        }
                        .buttonStyle(IconButtonStyle(size: 18, tint: DS.color.warning, hoverTint: DS.color.warning))
                        .help("取消收藏")
                    } else {
                        Button(action: toggleFavorite) {
                            AppIcon(symbol: "star", size: 10, tint: DS.color.textTertiary)
                        }
                        .buttonStyle(IconButtonStyle(size: 18, tint: DS.color.textTertiary, hoverTint: DS.color.warning))
                        .opacity(isHovering ? 1 : 0)
                        .disabled(!isHovering)
                        .help("收藏，置顶到「收藏」区")
                    }
                }
            }
            .frame(width: 18)
            .padding(.trailing, DS.space.sm)
            .animation(DS.motion.hover, value: isHovering)
            .animation(DS.motion.select, value: isFavorite)
        }
        .rowHighlight(isSelected: isSelected, horizontalInset: DS.space.xs, hovering: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        .help(row.node.name)
    }

    private func toggleFavorite() {
        guard let projectID = store.activeProjectID, let requestID = row.node.requestID else { return }
        store.toggleFavorite(projectID: projectID, requestID: requestID)
    }

    /// 层级引导线：每层一道极细竖线，深层目录的归属一眼看清。
    private var indentGuides: some View {
        HStack(spacing: 0) {
            ForEach(0..<row.level, id: \.self) { _ in
                Rectangle()
                    .fill(DS.color.hairline)
                    .frame(width: 1)
                    .padding(.leading, 5)
                    .padding(.trailing, DS.metric.treeIndent - 6)
            }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.isFolder {
            AppIcon(symbol: "chevron.right", size: 8, weight: .bold, tint: DS.color.textTertiary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .frame(width: 10)
                .animation(DS.motion.select, value: row.isExpanded)
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if row.isFolder {
            HStack(spacing: DS.space.sm) {
                AppIcon(
                    symbol: row.isExpanded ? "folder.fill" : "folder",
                    size: 10,
                    tint: row.isExpanded ? DS.color.brand : DS.color.textTertiary
                )
                Text(row.node.name)
                    .font(DS.font.bodyMedium)
                    .foregroundStyle(DS.color.textPrimary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: DS.space.sm) {
                MethodBadge(method: row.method ?? .get, compact: true)
                Text(row.node.name)
                    .font(DS.font.body)
                    .foregroundStyle(isSelected ? DS.color.textPrimary : DS.color.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func handleTap() {
        guard let projectID = store.activeProjectID else { return }
        if row.isFolder {
            store.toggleFolder(projectID: projectID, nodeID: row.node.id)
        } else if let requestID = row.node.requestID {
            store.openRequest(projectID: projectID, requestID: requestID, reveal: false)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let projectID = store.activeProjectID {
            if row.isFolder {
                Button("新建请求") {
                    if let requestID = store.addRequest(projectID: projectID, folderID: row.node.id) {
                        store.openRequest(projectID: projectID, requestID: requestID)
                    }
                }
                Button("新建子文件夹") {
                    store.addFolder(projectID: projectID, parentID: row.node.id)
                }
                Divider()
                Button("重命名…") {
                    ui.ask(title: "重命名文件夹", initialValue: row.node.name, confirmTitle: "保存") { name in
                        store.renameNode(projectID: projectID, nodeID: row.node.id, name: name)
                    }
                }
                Button(row.isExpanded ? "折叠" : "展开") {
                    store.toggleFolder(projectID: projectID, nodeID: row.node.id)
                }
                Divider()
                Button("删除文件夹", role: .destructive) { confirmDelete(node: row.node) }
            } else if let requestID = row.node.requestID {
                Button("打开") {
                    store.openRequest(projectID: projectID, requestID: requestID, reveal: false)
                }
                Button(isFavorite ? "取消收藏" : "收藏") {
                    toggleFavorite()
                }
                Divider()
                Button("重命名…") {
                    ui.ask(title: "重命名接口", initialValue: row.node.name, confirmTitle: "保存") { name in
                        store.renameNode(projectID: projectID, nodeID: row.node.id, name: name)
                    }
                }
                Button("复制为 cURL") { copyCurl(requestID: requestID, projectID: projectID) }
                Divider()
                Button("删除接口", role: .destructive) { confirmDelete(node: row.node) }
            }
        }
    }

    private func confirmDelete(node: CollectionNode) {
        guard let projectID = store.activeProjectID else { return }
        let childRequests = node.children.containedRequestIDs().count
        let message = node.kind == .folder && childRequests > 0
            ? "文件夹内的 \(childRequests) 个接口会一起删除，且不可撤销。"
            : "删除后不可撤销。"
        ui.askDelete(title: "删除「\(node.name)」？", message: message) {
            store.deleteNode(projectID: projectID, nodeID: node.id)
        }
    }

    private func copyCurl(requestID: UUID, projectID: UUID) {
        guard let project = store.project(id: projectID),
              let request = project.request(id: requestID) else { return }
        do {
            let resolved = try RequestBuilder.resolve(
                request: request,
                project: project,
                environment: project.activeEnvironment,
                runtimeVariables: store.runtimeVariables
            )
            let command = RequestBuilder.curlCommand(for: resolved)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            store.setNotice("已复制 cURL 到剪贴板")
        } catch {
            store.setNotice("生成 cURL 失败：\(error.localizedDescription)", level: .error)
        }
    }
}


// MARK: - 收藏区行

/// 收藏区里的一行：扁平（无层级），方法徽标 + 名称 + 行尾金星。
struct FavoriteRowView: View {
    @Environment(AppStore.self) private var store

    let request: APIRequest
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: DS.space.sm) {
                    // 与树内请求行相同的缩进量，保持两区左缘对齐
                    Color.clear.frame(width: 10, height: 1)
                    MethodBadge(method: request.method, compact: true)
                    Text(request.name)
                        .font(DS.font.body)
                        .foregroundStyle(isSelected ? DS.color.textPrimary : DS.color.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, DS.space.md)
                .frame(height: DS.metric.listRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle(scale: 0.99))

            Button(action: unfavorite) {
                AppIcon(symbol: "star.fill", size: 10, tint: DS.color.warning)
            }
            .buttonStyle(IconButtonStyle(size: 18, tint: DS.color.warning, hoverTint: DS.color.textTertiary))
            .frame(width: 18)
            .padding(.trailing, DS.space.sm)
            .help("取消收藏")
        }
        .rowHighlight(isSelected: isSelected, horizontalInset: DS.space.xs)
        .contextMenu {
            Button("打开") { open() }
            Button("取消收藏") { unfavorite() }
        }
        .help(request.name)
    }

    private func open() {
        guard let projectID = store.activeProjectID else { return }
        store.openRequest(projectID: projectID, requestID: request.id, reveal: false)
    }

    private func unfavorite() {
        guard let projectID = store.activeProjectID else { return }
        store.toggleFavorite(projectID: projectID, requestID: request.id)
    }
}


// MARK: - 搜索结果行

/// 搜索结果里的一行：方法徽标 + 名称 + URL（两行），行尾星标。
/// 名称是「这是什么」，URL 是「为什么搜到它」——按 URL 搜的时候第二行就是答案。
struct SearchResultRow: View {
    @Environment(AppStore.self) private var store

    let result: RequestSearch.Result
    /// 已小写、去首尾空白的搜索词（父视图算一次，每行不必再各自处理）。
    let query: String
    let isSelected: Bool
    let isFavorite: Bool
    /// 键盘光标停在这一行（↑↓ 选中、⏎ 打开）。
    var isHighlighted = false

    @State private var isHovering = false

    private var request: APIRequest { result.request }

    /// 优先展示原始 URL；如果它是靠「拼上 baseURL 的完整地址」命中的，
    /// 就展示完整地址——不然用户看不懂为什么这条被搜到。
    private var displayURL: String {
        let raw = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return result.fullURL.isEmpty ? "（无地址）" : result.fullURL }
        if !raw.lowercased().contains(query), result.fullURL.lowercased().contains(query) {
            return result.fullURL
        }
        return raw
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: DS.space.sm) {
                    MethodBadge(method: request.method, compact: true)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.name)
                            .font(DS.font.bodyMedium)
                            .foregroundStyle(isSelected ? DS.color.textPrimary : DS.color.textPrimary.opacity(0.85))
                            .lineLimit(1)
                        Text(displayURL)
                            .font(DS.font.monoTiny)
                            .foregroundStyle(DS.color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, DS.space.md)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle(scale: 0.99))

            Button(action: toggleFavorite) {
                AppIcon(
                    symbol: isFavorite ? "star.fill" : "star",
                    size: 10,
                    tint: isFavorite ? DS.color.warning : DS.color.textTertiary
                )
            }
            .buttonStyle(
                IconButtonStyle(
                    size: 18,
                    tint: isFavorite ? DS.color.warning : DS.color.textTertiary,
                    hoverTint: DS.color.warning
                )
            )
            .opacity(isFavorite || isHovering ? 1 : 0)
            .disabled(!isFavorite && !isHovering)
            .frame(width: 18)
            .padding(.trailing, DS.space.sm)
            .help(isFavorite ? "取消收藏" : "收藏")
        }
        .rowHighlight(isSelected: isSelected, horizontalInset: DS.space.xs, hovering: isHovering || isHighlighted)
        .onHover { isHovering = $0 }
        .animation(DS.motion.hover, value: isHovering)
        .contextMenu {
            Button("打开") { open() }
            Button(isFavorite ? "取消收藏" : "收藏") { toggleFavorite() }
            Divider()
            Button("复制为 cURL") { copyCurl() }
        }
        .help(request.name)
    }

    private func open() {
        guard let projectID = store.activeProjectID else { return }
        store.openRequest(projectID: projectID, requestID: request.id)
    }

    private func toggleFavorite() {
        guard let projectID = store.activeProjectID else { return }
        store.toggleFavorite(projectID: projectID, requestID: request.id)
    }

    private func copyCurl() {
        guard let project = store.activeProject else { return }
        do {
            let resolved = try RequestBuilder.resolve(
                request: request,
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
}
