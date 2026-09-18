import AppKit
import SwiftUI
import ApiClientCore

/// Mock 分区：后端没就绪 / 服务起不来时，也能把前端链路跑通。
///
/// 响应体默认**按请求自动生成**（跟着请求方法与请求体方式走），
/// 想固定几组返回值时再手写覆盖——手写内容按请求体方式分开存。
struct MockEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(UIState.self) private var ui

    let session: TabSession

    @State private var subPane: SubPane = .body
    @State private var locateToken = 0
    /// 「按请求自动生成」的预览。生成要做一次完整的请求编排（form-data 会读文件），
    /// 所以只在请求内容停顿后算一次，不跟着每次刷新算。
    @State private var generated = MockBody(text: "", contentType: "application/json")
    @State private var hasGeneratedPreview = false

    enum SubPane: String, CaseIterable, Identifiable {
        case body
        case headers

        var id: String { rawValue }
        var title: String { self == .body ? "模拟响应体" : "响应头" }
    }

    private var config: MockConfig { session.buffer.mock }
    private var kind: RequestBodyKind { session.effectiveMockKind }
    private var customBody: String { config.customBody(for: kind) }
    private var isMocking: Bool { store.settings.shouldMock(session.buffer) }

    /// 可编辑的响应体方式。「跟随」= 跟着请求体的方式走。
    private var kindOptions: [MockKindOption] {
        [.follow, .kind(.json), .kind(.raw), .kind(.formURLEncoded), .kind(.formData)]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            hairline
            SectionTabBar(
                items: SubPane.allCases,
                title: { $0.title },
                badge: { badge(for: $0) },
                accent: { $0 == .headers && isMocking ? DS.color.brand : nil },
                selection: $subPane
            )
            .background(DS.color.surface)
            hairline

            switch subPane {
            case .body:
                bodyEditor
            case .headers:
                headersEditor
            }
        }
        .background(DS.color.sunken)
        .onChange(of: kind) { _, _ in locateToken += 1 }
        .onChange(of: session.id) { _, _ in locateToken += 1 }
        .task(id: session.buffer) {
            // 首次进入立刻算一次；之后编辑请求时等停顿再算，不跟着每次按键重新编排。
            if hasGeneratedPreview {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            generated = store.generatedMockBody(for: session)
            hasGeneratedPreview = true
        }
    }

    private var hairline: some View {
        Rectangle().fill(DS.color.hairline).frame(height: 1)
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: DS.space.lg) {
            HStack(spacing: DS.space.sm) {
                Toggle("", isOn: mockEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("启用 Mock")
                    .font(DS.font.captionMedium)
                    .foregroundStyle(config.isEnabled ? DS.color.textPrimary : DS.color.textSecondary)
            }
            .help(modeHelp)

            if isMocking {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "wand.and.rays", size: 9, tint: DS.color.brand)
                    Text(store.settings.mockMode == .always ? "全量 Mock" : "命中 Mock")
                        .font(DS.font.micro)
                        .foregroundStyle(DS.color.brand)
                }
                .padding(.horizontal, DS.space.sm)
                .padding(.vertical, 1.5)
                .background(DS.color.brandSoft, in: Capsule())
            }

            Divider().frame(height: 16)

            statusMenu
            delayField

            Spacer(minLength: DS.space.md)

            Button {
                fillGenerated()
            } label: {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "wand.and.stars", size: 10, tint: DS.color.brand)
                    Text("按请求生成")
                        .font(DS.font.caption)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
            .help("用当前请求的方法与请求体生成一份响应体，填进编辑器后可以继续改")

            Button("清空") {
                store.updateBuffer(tabID: session.id) { $0.mock.setCustomBody("", for: kind) }
            }
            .buttonStyle(AppButtonStyle(kind: .ghost, size: .small))
            .disabled(customBody.isEmpty)
            .help("清空后回到「按请求自动生成」")
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: DS.metric.barHeight)
        .background(DS.color.surface)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(MockConfig.presetStatusCodes, id: \.self) { code in
                Button {
                    store.updateBuffer(tabID: session.id) { $0.mock.statusCode = code }
                } label: {
                    Text("\(code)  \(MockConfig.statusText(for: code))")
                }
            }
            Divider()
            Button("自定义状态码…") {
                ui.ask(
                    title: "自定义状态码",
                    message: "3 位数字，例如 418",
                    placeholder: "200",
                    initialValue: "\(config.statusCode)",
                    confirmTitle: "设置"
                ) { text in
                    guard let code = Int(text.trimmingCharacters(in: .whitespaces)), (100...599).contains(code) else {
                        store.setNotice("状态码需要在 100–599 之间", level: .error)
                        return
                    }
                    store.updateBuffer(tabID: session.id) { $0.mock.statusCode = code }
                }
            }
        } label: {
            HStack(spacing: DS.space.sm) {
                AppIcon(symbol: "number", size: 10, tint: StatusPalette.color(for: config.statusCode))
                Text("\(config.statusCode)")
                    .font(DS.font.monoSmall)
                    .foregroundStyle(DS.color.textPrimary)
                Text(MockConfig.statusText(for: config.statusCode))
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
                AppIcon(symbol: "chevron.down", size: 7, weight: .bold, tint: DS.color.textTertiary)
            }
            .padding(.horizontal, DS.space.md)
            .frame(height: 24)
            .background(
                StatusPalette.soft(for: config.statusCode),
                in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mock 返回的状态码，可以用 4xx / 5xx 验证前端的异常分支")
    }

    private var delayField: some View {
        HStack(spacing: DS.space.xs) {
            AppIcon(symbol: "clock", size: 10, tint: DS.color.textTertiary)
            TextField("", value: delayBinding, format: .number)
                .textFieldStyle(.plain)
                .font(DS.font.monoSmall)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, DS.space.sm)
                .frame(width: 56, height: 24)
                .background(DS.color.field, in: RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous))
            Text("ms 延迟")
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
        }
        .help("模拟网络延迟，用来验证 loading 与超时分支")
    }

    // MARK: 响应体

    @ViewBuilder
    private var bodyEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.space.md) {
                ChipTabBar(
                    items: kindOptions,
                    title: { $0.title(requestKind: session.buffer.body.kind) },
                    symbol: { $0.symbol },
                    accent: { $0.accent },
                    selection: kindBinding
                )
                .frame(width: 268)

                Spacer(minLength: DS.space.md)

                if customBody.isEmpty {
                    Text("未填写 → 按请求自动生成（\(generatedLineCount) 行 · \(generated.text.utf8.count) 字节）")
                        .font(DS.font.micro)
                        .foregroundStyle(DS.color.textTertiary)
                        .lineLimit(1)
                } else {
                    Text("已手写，不会再跟随请求")
                        .font(DS.font.micro)
                        .foregroundStyle(DS.color.textTertiary)
                }
            }
            .padding(.horizontal, DS.space.lg)
            .frame(height: DS.metric.barHeight)
            .background(DS.color.sunken)

            hairline

            CodeEditor(
                text: bodyBinding,
                language: kind == .raw ? .plain : .json,
                anchorKey: "mock-\(kind.rawValue)",
                anchorStore: anchorStore,
                locateToken: locateToken
            )
            .background(DS.color.sunken)
            .overlay(alignment: .topLeading) {
                if customBody.isEmpty {
                    Text(placeholder)
                        .font(DS.font.mono)
                        .foregroundStyle(DS.color.textTertiary)
                        .padding(.horizontal, DS.space.md + DS.space.lg)
                        .padding(.vertical, DS.space.lg)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var placeholder: String {
        kind == .raw
            ? "留空 = 按请求自动生成（Raw 会回显请求体原文）"
            : "留空 = 按请求自动生成\n生成规则：\(generationRule)"
    }

    private var generationRule: String {
        switch kind {
        case .none:
            return "无请求体"
        case .json:
            return "把请求体 JSON 镜像进 data"
        case .raw:
            return "以 text/plain 回显请求体原文"
        case .formURLEncoded:
            return "把表单字段整理成 JSON"
        case .formData:
            return "把 multipart 字段整理成 JSON（文件字段标出文件名）"
        }
    }

    private var headersEditor: some View {
        KeyValueTableEditor(
            items: headersBinding,
            keyPlaceholder: "响应头",
            valuePlaceholder: "值",
            addTitle: "添加响应头",
            emptyTitle: "没有自定义响应头"
        )
    }

    // MARK: 生成预览

    private var generatedLineCount: Int {
        generated.text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: 绑定与动作

    private var modeHelp: String {
        switch store.settings.mockMode {
        case .off: return "Mock 已在设置里关闭（当前为「关闭」），打开接口开关也不会生效"
        case .perRequest: return "打开后该接口的发送不会走真实网络"
        case .always: return "当前设置为「全量 Mock」，所有请求都会返回模拟数据"
        }
    }

    private var mockEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.isEnabled },
            set: { newValue in
                if newValue, store.settings.mockMode == .off {
                    store.setNotice("Mock 已在设置里关闭，可在「设置 → Mock」改为按接口生效", level: .error)
                    return
                }
                store.updateBuffer(tabID: session.id) { $0.mock.isEnabled = newValue }
            }
        )
    }

    private var delayBinding: Binding<Int> {
        Binding(
            get: { config.delayMs },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0.mock.delayMs = max(0, min(newValue, 60_000)) }
            }
        )
    }

    private var kindBinding: Binding<MockKindOption> {
        Binding(
            get: { session.mockEditingKind.map(MockKindOption.kind) ?? .follow },
            set: { newValue in
                session.mockEditingKind = newValue.kind
            }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { session.buffer.mock.customBody(for: kind) },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0.mock.setCustomBody(newValue, for: kind) }
            }
        )
    }

    private var headersBinding: Binding<[KeyValueItem]> {
        Binding(
            get: { session.buffer.mock.headers },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0.mock.headers = newValue }
            }
        )
    }

    private var anchorStore: Binding<[String: BodyEditorAnchor]> {
        Binding(
            get: { session.bodyAnchors },
            set: { session.bodyAnchors = $0 }
        )
    }

    private func fillGenerated() {
        let text = store.generatedMockBody(for: session).text
        store.updateBuffer(tabID: session.id) { $0.mock.setCustomBody(text, for: kind) }
        session.bodyAnchors.removeValue(forKey: "mock-\(kind.rawValue)")
        locateToken += 1
        store.setNotice("已按请求生成 Mock 响应体，可以直接修改")
    }

    private func badge(for pane: SubPane) -> String? {
        switch pane {
        case .body: return customBody.isEmpty ? nil : "手写"
        case .headers:
            let count = config.headers.activeItems.count
            return count > 0 ? "\(count)" : nil
        }
    }
}

// MARK: - Mock 响应体方式选项

/// 编辑器顶部的「跟随 / JSON / Raw / Form」。
enum MockKindOption: Hashable, Identifiable {
    case follow
    case kind(RequestBodyKind)

    var id: String {
        switch self {
        case .follow: return "follow"
        case .kind(let kind): return kind.rawValue
        }
    }

    var kind: RequestBodyKind? {
        switch self {
        case .follow: return nil
        case .kind(let kind): return kind
        }
    }

    func title(requestKind: RequestBodyKind) -> String {
        switch self {
        case .follow: return "跟随请求（\(requestKind.title)）"
        case .kind(let kind): return kind.title
        }
    }

    var symbol: String {
        switch self {
        case .follow: return "arrow.triangle.branch"
        case .kind(let kind): return kind.toolbarSymbol
        }
    }

    var accent: Color? {
        switch self {
        case .follow: return DS.color.brand
        case .kind(let kind): return kind.accent
        }
    }
}
