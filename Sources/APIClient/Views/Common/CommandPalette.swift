import SwiftUI
import ApiClientCore

/// ⌘K 命令面板：跨项目跳接口。
///
/// 侧边栏的搜索只搜当前项目，而这个工作区里有 9 个项目、两千多个接口，
/// "我记得有个接口叫 xxx，但不记得在哪个项目"是日常。面板直接搜全部项目，
/// 回车就切过去并打开——不用先切项目再搜。
///
/// 搜索复用 `RequestSearch`（与侧边栏同一套评分），输入停顿后在后台线程跑一次。
struct CommandPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    @State private var query = ""
    @State private var highlighted = 0
    @State private var hits: [Hit] = []
    @FocusState private var isFocused: Bool

    struct Hit: Identifiable, Sendable {
        let projectID: UUID
        let projectName: String
        let request: APIRequest
        let score: Int
        var id: UUID { request.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(DS.color.hairline).frame(height: 1)
            results
        }
        .frame(width: 620, height: 420)
        .background(DS.color.surface)
        .task {
            // sheet 要等窗口成为 key 之后才接收键盘事件，立刻设焦点会被丢掉，
            // 结果是面板弹出来但打字进不去。等一帧再抢焦点。
            try? await Task.sleep(for: .milliseconds(80))
            isFocused = true
        }
        .task(id: query) { await runSearch() }
    }

    private var field: some View {
        HStack(spacing: DS.space.md) {
            AppIcon(symbol: "magnifyingglass", size: 13, tint: DS.color.textSecondary)

            TextField("跳转到接口——搜名称、地址或备注，搜全部项目", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isFocused)
                .onSubmit { openHighlighted() }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) { ui.commandPalette = false; return .handled }

            if !hits.isEmpty {
                Text("\(hits.count) 条")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textSecondary)
            }
        }
        .padding(.horizontal, DS.space.xl)
        .frame(height: 52)
    }

    @ViewBuilder
    private var results: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hint("输入关键词开始搜索", detail: "↑↓ 选择 · ⏎ 打开 · esc 关闭")
        } else if hits.isEmpty {
            hint("没有匹配的接口", detail: "试试接口名的一部分，或 /path 片段")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            row(hit: hit, isHighlighted: index == highlighted)
                                .id(index)
                                .onTapGesture { open(hit) }
                        }
                    }
                    .padding(.vertical, DS.space.xs)
                }
                .onChange(of: highlighted) { _, value in
                    withAnimation(DS.motion.hover) { proxy.scrollTo(value, anchor: .center) }
                }
            }
        }
    }

    private func hint(_ title: String, detail: String) -> some View {
        VStack(spacing: DS.space.sm) {
            Text(title)
                .font(DS.font.body)
                .foregroundStyle(DS.color.textSecondary)
            Text(detail)
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.color.sunken)
    }

    private func row(hit: Hit, isHighlighted: Bool) -> some View {
        HStack(spacing: DS.space.md) {
            MethodBadge(method: hit.request.method, compact: true)

            VStack(alignment: .leading, spacing: 1) {
                Text(hit.request.name)
                    .font(DS.font.bodyMedium)
                    .foregroundStyle(DS.color.textPrimary)
                    .lineLimit(1)
                Text(hit.request.url.isEmpty ? "（无地址）" : hit.request.url)
                    .font(DS.font.monoSmall)
                    .foregroundStyle(DS.color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DS.space.md)

            Text(hit.projectName)
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, DS.space.sm)
                .padding(.vertical, 1)
                .background(DS.color.field, in: Capsule())
        }
        .padding(.horizontal, DS.space.xl)
        .frame(height: 44)
        .background(isHighlighted ? DS.color.rowSelected : .clear)
        .contentShape(Rectangle())
    }

    // MARK: 搜索

    private func runSearch() async {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            hits = []
            highlighted = 0
            return
        }
        // 跨项目搜两千多条，等输入停一下再跑，避免每敲一个字全量算一遍。
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }

        // 先把要搜的东西快照成纯数据，再丢到后台：两千多条接口逐个比分，
        // 放主线程会让输入卡顿。
        let snapshot = store.projects.map {
            ProjectSnapshot(
                id: $0.id,
                name: $0.name,
                requests: $0.requests,
                baseURL: $0.activeEnvironment?.baseURL ?? ""
            )
        }
        // 当前项目优先：同样相关度下，手边的那个更可能是想找的。
        let activeID = store.activeProjectID

        let found = await Task.detached(priority: .userInitiated) {
            snapshot
                .flatMap { project in
                    RequestSearch.search(project.requests, query: raw, baseURL: project.baseURL)
                        .map {
                            Hit(
                                projectID: project.id,
                                projectName: project.name,
                                request: $0.request,
                                score: $0.score
                            )
                        }
                }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    let lhsActive = lhs.projectID == activeID
                    let rhsActive = rhs.projectID == activeID
                    if lhsActive != rhsActive { return lhsActive }
                    return lhs.request.name < rhs.request.name
                }
                .prefix(120)
        }.value

        guard !Task.isCancelled else { return }
        hits = Array(found)
        highlighted = 0
    }

    private struct ProjectSnapshot: Sendable {
        let id: UUID
        let name: String
        let requests: [APIRequest]
        let baseURL: String
    }

    // MARK: 操作

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !hits.isEmpty else { return .ignored }
        highlighted = (highlighted + delta + hits.count) % hits.count
        return .handled
    }

    private func openHighlighted() {
        guard hits.indices.contains(highlighted) else { return }
        open(hits[highlighted])
    }

    private func open(_ hit: Hit) {
        store.openRequest(projectID: hit.projectID, requestID: hit.request.id)
        ui.commandPalette = false
    }
}
