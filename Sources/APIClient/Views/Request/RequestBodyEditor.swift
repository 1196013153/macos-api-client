import AppKit
import SwiftUI
import ApiClientCore

/// 请求体编辑器（只负责内容区）。
///
/// 方式条与格式化等操作在 `RequestBodyToolbar`，渲染在分区标签行右侧。
/// 这里保留的体验点：正文用带 JSON 高亮的编辑器，**每种方式各自记住光标与滚动位置**，
/// 切来切去、切标签再切回来，位置都不丢；头一次进入则定位到正文起点，
/// 而不是停在 JSON 前面那几行空行上。
struct RequestBodyEditor: View {
    @Environment(AppStore.self) private var store

    let session: TabSession

    private var kind: RequestBodyKind { session.buffer.body.kind }
    private var text: String { session.buffer.body.text }

    var body: some View {
        content
            .background(DS.color.sunken)
            .onChange(of: kind) { _, _ in session.bodyLocateToken += 1 }
            .onChange(of: session.id) { _, _ in session.bodyLocateToken += 1 }
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
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
            if session.bodyValidation == false {
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
                locateToken: session.bodyLocateToken
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
