import AppKit
import SwiftUI
import ApiClientCore

struct ResponsePanelView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let session: TabSession

    @State private var expandDepth = 2
    /// 树形视图的字段筛选词（视图态，换标签不带走）。
    @State private var treeFilter = ""
    @FocusState private var isFilterFocused: Bool

    /// 停在哪个分区 / 用哪种展示方式，都记在标签自己身上，切标签不会互相干扰。
    private var pane: Binding<ResponsePane> {
        Binding(
            get: { session.responsePane },
            set: { session.responsePane = $0 }
        )
    }

    private var bodyMode: Binding<ResponseBodyMode> {
        Binding(
            get: { session.responseBodyMode },
            set: { session.responseBodyMode = $0 }
        )
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
    }

    /// 驱动状态切换动画的签名。
    private var stateKey: String {
        if session.prepareError != nil { return "prepare-error" }
        guard let payload = session.response else { return session.isSending ? "sending" : "idle" }
        if payload.errorMessage != nil { return "failed" }
        // 流式响应：事件不断到达时 key 保持不变，否则每批事件都会触发一次状态切换动画。
        if let stream = payload.stream { return stream.isOpen ? "stream-open" : "stream-closed" }
        return "ok-\(payload.statusCode)-\(payload.size)-\(payload.elapsed)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 状态（左）· 分区标签（中）· 当前分区的工具（右）合成一行。
            // 原先状态条和分区标签各占一行，合并后省下整整 32px 给响应内容。
            if session.response != nil || session.isSending {
                SectionTabBar(
                    items: ResponsePane.allCases,
                    title: { $0.title },
                    badge: { badge(for: $0) },
                    accent: { $0 == .body && session.response?.isMock == true ? DS.color.brand : nil },
                    selection: pane,
                    leading: { statusGroup },
                    trailing: { paneTools }
                )
                .background(DS.color.surface)
            } else {
                idleBar
            }
            hairline
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.color.sunken)
        .animation(DS.motion.enter, value: stateKey)
    }

    // MARK: 状态与工具

    /// 还没有响应时的一条轻提示。没有分区可切，就不摆整行标签。
    private var idleBar: some View {
        HStack(spacing: DS.space.sm) {
            Text("等待发送")
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: DS.metric.barHeight)
        .background(DS.color.surface)
    }

    /// 分区行最左：状态码、耗时、大小这类「发送后第一眼要看」的信息。
    @ViewBuilder
    private var statusGroup: some View {
        HStack(spacing: DS.space.md) {
            if let payload = session.response {
                StatusBadge(
                    code: payload.statusCode,
                    text: payload.statusText,
                    failed: payload.isFailed
                )

                MetaChip(symbol: "clock", text: payload.elapsedText, help: "总耗时")

                if let stream = payload.stream {
                    HStack(spacing: DS.space.xs) {
                        if stream.isOpen {
                            SpinnerDot(color: DS.color.info, size: 9)
                        } else {
                            AppIcon(symbol: "dot.radiowaves.left.and.right", size: 9, tint: DS.color.info)
                        }
                        Text("SSE")
                            .font(DS.font.badgeSmall)
                            .foregroundStyle(DS.color.info)
                        Text("\(stream.events.count) 个事件")
                            .font(DS.font.monoSmall)
                            .foregroundStyle(DS.color.info)
                    }
                    .padding(.horizontal, DS.space.sm)
                    .padding(.vertical, 2)
                    .background(DS.color.infoSoft, in: Capsule())
                    .help(stream.isOpen ? "流式响应接收中，点「取消」可停止" : "流式响应已结束：\(stream.endReason ?? "")")
                }

                if payload.isMock {
                    HStack(spacing: DS.space.xs) {
                        AppIcon(symbol: "wand.and.rays", size: 9, tint: DS.color.brand)
                        Text("MOCK")
                            .font(DS.font.badgeSmall)
                            .foregroundStyle(DS.color.brand)
                    }
                    .padding(.horizontal, DS.space.sm)
                    .padding(.vertical, 2)
                    .background(DS.color.brandSoft, in: Capsule())
                    .help("这份响应由 Mock 生成，没有发出真实网络请求")
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                MetaChip(symbol: "arrow.up.arrow.down", text: payload.sizeText, help: "响应体大小")

                if let contentType = payload.contentType {
                    Text(contentType.split(separator: ";").first.map(String.init) ?? contentType)
                        .font(DS.font.monoTiny)
                        .foregroundStyle(DS.color.textTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                }

                if let finalURL = payload.finalURL, finalURL.absoluteString != payload.requestURL {
                    HStack(spacing: DS.space.xs) {
                        AppIcon(symbol: "arrow.triangle.branch", size: 9, tint: DS.color.warning)
                        Text("已重定向")
                            .font(DS.font.caption)
                            .foregroundStyle(DS.color.warning)
                    }
                    .help(finalURL.absoluteString)
                }
            } else if session.isSending {
                HStack(spacing: DS.space.sm) {
                    SpinnerDot(size: 11)
                    Text("请求中…")
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textSecondary)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 分区行最右：当前分区自己的操作。原文/树形、字段筛选、展开层级、复制。
    @ViewBuilder
    private var paneTools: some View {
        HStack(spacing: DS.space.md) {
            if let payload = session.response, payload.jsonValue != nil, session.responsePane == .body {
                Picker("", selection: bodyMode) {
                    ForEach(ResponseBodyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 128)

                if session.responseBodyMode == .tree {
                    HStack(spacing: DS.space.xs) {
                        AppIcon(symbol: "line.3.horizontal.decrease", size: 9, tint: DS.color.textTertiary)
                        TextField("筛选字段", text: $treeFilter)
                            .textFieldStyle(.plain)
                            .font(DS.font.caption)
                            .focused($isFilterFocused)
                            .onKeyPress(.escape) {
                                treeFilter = ""
                                isFilterFocused = false
                                return .handled
                            }
                        if !treeFilter.isEmpty {
                            Button {
                                treeFilter = ""
                            } label: {
                                AppIcon(symbol: "xmark.circle.fill", size: 9, tint: DS.color.textTertiary)
                            }
                            .buttonStyle(IconButtonStyle(size: 14, tint: DS.color.textTertiary))
                        }
                    }
                    .padding(.horizontal, DS.space.sm)
                    .frame(width: 132, height: 22)
                    .background(DS.color.field, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                            .strokeBorder(isFilterFocused ? DS.color.brand.opacity(0.5) : DS.color.hairline)
                    )
                    .help("按字段名或值筛选树形视图，只显示命中的路径")

                    Menu {
                        Button("展开两层") { expandDepth = 2 }
                        Button("展开全部") { expandDepth = 99 }
                        Button("只展开根节点") { expandDepth = 1 }
                    } label: {
                        AppIcon(
                            symbol: "chevron.up.chevron.down",
                            size: 10,
                            weight: .semibold,
                            tint: DS.color.textSecondary
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .help("展开层级")
                }
            }

            if session.response != nil {
                Button {
                    copyBody()
                } label: {
                    AppIcon(symbol: "doc.on.doc", size: 11, tint: DS.color.textSecondary)
                }
                .buttonStyle(IconButtonStyle(size: 24, tint: DS.color.textSecondary))
                .help("复制响应体")

                Button {
                    copyCurl()
                } label: {
                    AppIcon(symbol: "terminal", size: 11, tint: DS.color.textSecondary)
                }
                .buttonStyle(IconButtonStyle(size: 24, tint: DS.color.textSecondary))
                .help("复制为 cURL")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: 内容分发

    @ViewBuilder
    private var content: some View {
        // 流式响应一建立连接就有 response，直接展示事件列表，不再停在骨架屏上。
        if session.isSending, session.response == nil {
            loadingState
        } else if let prepareError = session.prepareError {
            errorState(title: "请求未发出", message: prepareError, hints: [])
        } else if let payload = session.response {
            if let error = payload.errorMessage {
                errorState(title: "请求失败", message: error, hints: payload.unresolvedVariables)
            } else {
                responseContent(payload)
            }
        } else {
            EmptyState(
                art: .response,
                title: "还没有响应",
                subtitle: "按 ⌘↵ 或点击「发送」发起请求"
            )
        }
    }

    // MARK: 加载中

    private var loadingState: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.space.sm) {
                SpinnerDot(size: 12)
                Text("\(session.buffer.method.rawValue) \(store.previewURL(for: session)?.url ?? session.buffer.url)")
                    .font(DS.font.monoSmall)
                    .foregroundStyle(DS.color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.space.lg)
            .padding(.vertical, DS.space.lg)

            ResponseSkeleton()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: 错误

    private func errorState(title: String, message: String, hints: [String]) -> some View {
        VStack(spacing: DS.space.lg) {
            ZStack {
                Circle()
                    .fill(DS.color.dangerSoft)
                    .frame(width: 52, height: 52)
                AppIcon(symbol: "exclamationmark.octagon.fill", size: 22, tint: DS.color.danger)
            }

            VStack(spacing: DS.space.xs) {
                Text(title)
                    .font(DS.font.heading)
                    .foregroundStyle(DS.color.textPrimary)
                Text(message)
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }

            if !hints.isEmpty {
                Text("未解析变量：\(hints.map { "{{\($0)}}" }.joined(separator: "、"))")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
            }
        }
        .padding(DS.space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 正常响应

    @ViewBuilder
    private func responseContent(_ payload: HTTPResponsePayload) -> some View {
        VStack(spacing: 0) {
            if !payload.unresolvedVariables.isEmpty {
                HStack(spacing: DS.space.sm) {
                    AppIcon(symbol: "exclamationmark.triangle.fill", size: 10, tint: DS.color.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("有未解析的变量：\(payload.unresolvedVariables.map { "{{\($0)}}" }.joined(separator: "、"))")
                            .font(DS.font.caption)
                            .foregroundStyle(DS.color.textPrimary)
                        Text("这些变量在当前环境 / 全局变量里没有定义，已按字面量发出。")
                            .font(DS.font.micro)
                            .foregroundStyle(DS.color.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.space.lg)
                .padding(.vertical, DS.space.sm)
                .background(DS.color.warningSoft)
                hairline
            }

            switch session.responsePane {
            case .body:
                bodyContent(payload)
            case .headers:
                headerList(payload)
            case .requestDetail:
                requestDetail()
            }
        }
    }

    @ViewBuilder
    private func bodyContent(_ payload: HTTPResponsePayload) -> some View {
        if let stream = payload.stream {
            SSEEventListView(stream: stream)
        } else if payload.body.isEmpty {
            EmptyState(
                art: .body,
                title: "响应体为空",
                subtitle: "服务端返回了 \(payload.statusCode)，但没有内容"
            )
        } else if let json = payload.jsonValue {
            switch session.responseBodyMode {
            case .tree:
                // 换了响应就重建整棵树（展开状态归零）；换展开深度由树自己处理，不必重建。
                JSONTreeView(value: json, expandDepth: expandDepth, filter: treeFilter)
                    .id("\(session.id)-\(stateKey)")
                    .transition(.opacity)
            case .raw:
                rawText(formattedRawText(payload), language: .json)
            }
        } else if let text = payload.text {
            rawText(text, language: .plain)
        } else {
            EmptyState(
                art: .body,
                title: "无法以文本解码响应体",
                subtitle: "共 \(payload.sizeText)，可在「请求详情」复制 cURL 用终端排查"
            )
        }
    }

    /// 原文模式下的展示文本：JSON 保序格式化，其他内容按服务端原文展示。
    private func formattedRawText(_ payload: HTTPResponsePayload) -> String {
        payload.jsonValue?.prettyPrinted() ?? (payload.text ?? "")
    }

    /// 原文视图：用只读的代码编辑器，JSON 会带高亮；横向滚动交给 NSTextView，不折行。
    private func rawText(_ text: String, language: CodeLanguage) -> some View {
        CodeEditor(text: .constant(text), language: language, isEditable: false)
            .background(DS.color.sunken)
    }

    private func headerList(_ payload: HTTPResponsePayload) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(payload.headers) { header in
                    ResponseHeaderRow(header: header)
                    hairline
                }
            }
        }
        .background(DS.color.sunken)
    }

    @ViewBuilder
    private func requestDetail() -> some View {
        if let project = store.project(id: session.projectID),
           let resolved = try? RequestBuilder.resolve(
               request: session.buffer,
               project: project,
               environment: project.activeEnvironment,
               runtimeVariables: store.runtimeVariables
           ) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.space.lg) {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: DS.space.md) {
                            SectionLabel(text: "实际请求")
                            DetailRow(name: "方法", value: resolved.method)
                            DetailRow(name: "地址", value: resolved.urlString, monospaced: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: DS.space.md) {
                            SectionLabel(text: "请求头", detail: "已合并项目全局请求头与自动 Content-Type")
                            if resolved.headers.isEmpty {
                                Text("（无）")
                                    .font(DS.font.caption)
                                    .foregroundStyle(DS.color.textTertiary)
                            } else {
                                ForEach(Array(resolved.headers.enumerated()), id: \.offset) { _, header in
                                    DetailRow(name: header.name, value: header.value, monospaced: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let body = resolved.body, let text = String(data: body, encoding: .utf8), !text.isEmpty {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: DS.space.md) {
                                SectionLabel(text: "请求体")
                                Text(text)
                                    .font(DS.font.mono)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    SurfaceCard {
                        VStack(alignment: .leading, spacing: DS.space.md) {
                            SectionLabel(text: "cURL", detail: "可直接粘贴到终端复现这次请求")
                            Text(RequestBuilder.curlCommand(for: resolved))
                                .font(DS.font.monoSmall)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(DS.space.lg)
            }
            .background(DS.color.sunken)
        } else {
            EmptyState(
                art: .search,
                title: "暂时算不出实际请求",
                subtitle: "地址为空或无法解析"
            )
        }
    }

    private func badge(for pane: ResponsePane) -> String? {
        switch pane {
        case .body:
            guard let payload = session.response else { return nil }
            if let stream = payload.stream { return "\(stream.events.count) 事件" }
            return payload.size > 0 ? payload.sizeText : nil
        case .headers:
            guard let payload = session.response else { return nil }
            return payload.headers.isEmpty ? nil : "\(payload.headers.count)"
        case .requestDetail:
            return nil
        }
    }

    // MARK: 动作

    private func copyBody() {
        guard let text = session.response?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.setNotice("已复制响应体")
    }

    private func copyCurl() {
        guard let project = store.project(id: session.projectID) else { return }
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
}

// MARK: - 响应头行

private struct ResponseHeaderRow: View {
    @Environment(AppStore.self) private var store

    let header: HeaderField

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.space.lg) {
            Text(header.name)
                .font(DS.font.monoSmall)
                .foregroundStyle(DS.color.textSecondary)
                .frame(width: 200, alignment: .leading)

            Text(header.value)
                .font(DS.font.monoSmall)
                .foregroundStyle(DS.color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(header.name): \(header.value)", forType: .string)
                    store.setNotice("已复制该响应头")
                } label: {
                    AppIcon(symbol: "doc.on.doc", size: 10, tint: DS.color.textTertiary)
                }
                .buttonStyle(IconButtonStyle(size: 18, tint: DS.color.textTertiary))
                .transition(.opacity)
                .help("复制这一行")
            }
        }
        .padding(.horizontal, DS.space.lg)
        .padding(.vertical, DS.space.sm)
        .background(isHovering ? DS.color.rowHover : Color.clear)
        .animation(DS.motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
    }
}
