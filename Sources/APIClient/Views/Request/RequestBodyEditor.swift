import AppKit
import SwiftUI
import ApiClientCore

/// 请求体编辑器。
///
/// 两个和「方式」相关的体验点：
/// - 方式条（JSON / Raw / Form …）会**自动把当前方式滚进视野**；
/// - 正文用带 JSON 高亮的编辑器，并且**每种方式各自记住光标与滚动位置**，
///   切来切去、切标签再切回来，位置都不丢；头一次进入则定位到正文起点，
///   而不是停在 JSON 前面那几行空行上。
struct RequestBodyEditor: View {
    @Environment(AppStore.self) private var store

    let session: TabSession

    /// 变化时让编辑器重新定位一次（切换方式 / 切换标签 / 格式化之后）。
    @State private var locateToken = 0

    private var kind: RequestBodyKind { session.buffer.body.kind }
    private var text: String { session.buffer.body.text }
    private var isTextBlank: Bool { text.first { !$0.isWhitespace } == nil }

    /// JSON 校验结果，nil 表示"不需要校验"（非 JSON 或内容为空）。
    /// 校验在输入停顿后于后台做一次：之前是计算属性，每次刷新都把整段请求体解析两遍。
    @State private var isJSONValid: Bool?

    private struct ValidationInput: Equatable {
        var kind: RequestBodyKind
        var text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            hairline
            content
        }
        .background(DS.color.sunken)
        .onChange(of: kind) { _, _ in locateToken += 1 }
        .onChange(of: session.id) { _, _ in locateToken += 1 }
        .task(id: ValidationInput(kind: kind, text: text)) { await validateJSON() }
    }

    private func validateJSON() async {
        guard kind == .json, !isTextBlank else {
            isJSONValid = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let source = text
        let valid = await Task.detached { JSONValueParser.parse(source) != nil }.value
        guard !Task.isCancelled else { return }
        isJSONValid = valid
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
    }

    // MARK: 工具条

    private var toolbar: some View {
        HStack(spacing: DS.space.md) {
            ChipTabBar(
                items: RequestBodyKind.allCases,
                title: { $0.title },
                symbol: { $0.toolbarSymbol },
                accent: { $0.accent },
                selection: kindBinding
            )
            // 五个方式并排的宽度：够宽时不滚动，超了才让 ChipTabBar 自己横向滚。
            .frame(width: 372)
            .help(kind.fullTitle)

            validationChip

            Spacer(minLength: DS.space.md)

            if kind == .json || kind == .raw, !text.isEmpty {
                Text("\(text.utf8.count) 字节")
                    .font(DS.font.monoTiny)
                    .foregroundStyle(DS.color.textTertiary)
            }

            Button {
                format()
            } label: {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "wand.and.stars", size: 10, tint: DS.color.brand)
                    Text("格式化")
                        .font(DS.font.caption)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
            .disabled(kind != .json || isTextBlank)
            .help("按 2 空格缩进重排 JSON")

            Button("清空") {
                store.updateBuffer(tabID: session.id) { $0.body.text = "" }
            }
            .buttonStyle(AppButtonStyle(kind: .ghost, size: .small))
            .disabled(kind == .none || text.isEmpty)
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: DS.metric.barHeight)
        .background(DS.color.surface)
    }

    @ViewBuilder
    private var validationChip: some View {
        if let isValid = isJSONValid {
            HStack(spacing: DS.space.xs) {
                AppIcon(
                    symbol: isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    size: 10,
                    tint: isValid ? DS.color.success : DS.color.warning
                )
                Text(isValid ? "JSON 合法" : "JSON 格式有误")
                    .font(DS.font.caption)
                    .foregroundStyle(isValid ? DS.color.success : DS.color.warning)
            }
            .padding(.horizontal, DS.space.md)
            .padding(.vertical, 2)
            .background(
                isValid ? DS.color.successSoft : DS.color.warningSoft,
                in: Capsule()
            )
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .animation(DS.motion.select, value: isValid)
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .none:
            EmptyState(
                art: .body,
                title: "不发送请求体",
                subtitle: "切换到 JSON、Raw 或 Form 来构造请求体"
            )
        case .json, .raw:
            editor
        case .formURLEncoded:
            KeyValueTableEditor(
                items: bodyFieldsBinding,
                keyPlaceholder: "字段名",
                valuePlaceholder: "字段值",
                addTitle: "添加字段",
                emptyTitle: "还没有表单字段"
            )
        case .formData:
            FormDataEditor(items: bodyFieldsBinding)
        }
    }

    @ViewBuilder
    private var editor: some View {
        VStack(spacing: 0) {
            if isJSONValid == false {
                HStack(spacing: DS.space.sm) {
                    AppIcon(symbol: "exclamationmark.triangle.fill", size: 10, tint: DS.color.warning)
                    Text("当前内容不是合法 JSON，发送时仍会按原文发出")
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.space.lg)
                .padding(.vertical, DS.space.sm)
                .background(DS.color.warningSoft)
                hairline
            }

            CodeEditor(
                text: textBinding,
                language: kind == .json ? .json : .plain,
                anchorKey: "body-\(kind.rawValue)",
                anchorStore: anchorStore,
                locateToken: locateToken
            )
            .background(DS.color.sunken)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
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
        kind == .json
            ? "{\n  \"key\": \"{{variable}}\"\n}"
            : "纯文本请求体，支持 {{变量}} 与 {{$timestamp}} 这类动态变量"
    }

    // MARK: 绑定

    private var kindBinding: Binding<RequestBodyKind> {
        Binding(
            get: { kind },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0.body.kind = newValue }
            }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { session.buffer.body.text },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0.body.text = newValue }
            }
        )
    }

    /// 位置记忆放在标签上（不参与观察，光标每动一下不该触发界面刷新）。
    private var anchorStore: Binding<[String: BodyEditorAnchor]> {
        Binding(
            get: { session.bodyAnchors },
            set: { session.bodyAnchors = $0 }
        )
    }

    private var bodyFieldsBinding: Binding<[KeyValueItem]> {
        Binding(
            get: { session.buffer.body.fields },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0.body.fields = newValue }
            }
        )
    }

    private func format() {
        guard let value = JSONValueParser.parse(text) else {
            store.setNotice("JSON 格式有误，无法格式化", level: .error)
            return
        }
        let pretty = value.prettyPrinted()
        store.updateBuffer(tabID: session.id) { $0.body.text = pretty }
        // 整段被重排了，旧的光标位置已经没有意义：清掉记忆，定位到正文起点。
        session.bodyAnchors.removeValue(forKey: "body-\(kind.rawValue)")
        locateToken += 1
        store.setNotice("已格式化 JSON")
    }
}

// MARK: - 请求体方式的视觉映射

extension RequestBodyKind {
    var toolbarSymbol: String {
        switch self {
        case .none: return "nosign"
        case .json: return "curlybraces"
        case .raw: return "text.alignleft"
        case .formURLEncoded: return "list.bullet"
        case .formData: return "paperclip"
        }
    }

    var accent: Color? {
        switch self {
        case .none: return nil
        case .json: return DS.color.warning
        case .raw: return DS.color.textSecondary
        case .formURLEncoded: return DS.color.info
        case .formData: return DS.color.brand
        }
    }

    /// 编辑器里的语言（JSON 上色，其余按纯文本）。
    var codeLanguage: CodeLanguage {
        self == .json ? .json : .plain
    }
}
