import SwiftUI
import ApiClientCore

/// 请求体的方式选择与操作（JSON / Raw / Form…、校验状态、格式化、清空）。
///
/// 它原本是正文编辑器自己的一条 36px 工具条。现在渲染在分区标签行的右侧——
/// 那一行本来就是空的，省下整整一行的垂直空间留给正文。
/// 校验结果与定位标记存在 `TabSession` 上，因为工具条和编辑器已经不在同一棵子树里。
struct RequestBodyToolbar: View {
    @Environment(AppStore.self) private var store

    let session: TabSession

    private var kind: RequestBodyKind { session.buffer.body.kind }
    private var text: String { session.buffer.body.text }
    private var isTextBlank: Bool { text.first { !$0.isWhitespace } == nil }

    private struct ValidationInput: Equatable {
        var kind: RequestBodyKind
        var text: String
    }

    var body: some View {
        HStack(spacing: DS.space.sm) {
            ChipTabBar(
                items: RequestBodyKind.allCases,
                title: { $0.title },
                symbol: { $0.toolbarSymbol },
                accent: { $0.accent },
                selection: kindBinding
            )
            // 五个方式并排的实际宽度。chip 带图标且 fixedSize（不压缩），
            // 给不够不会变窄、只会被裁成半截字（Form-data → Form）。
            // 窗口窄到装不下时由 ChipTabBar 自己横向滚，并把当前项滚进视野。
            .frame(width: 480)
            .help(kind.fullTitle)

            validationChip

            if kind == .json || kind == .raw, !text.isEmpty {
                Text("\(text.utf8.count) B")
                    .font(DS.font.monoTiny)
                    .foregroundStyle(DS.color.textSecondary)
                    .help("请求体字节数")
            }

            Button(action: format) {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "wand.and.stars", size: 10, tint: DS.color.brand)
                    Text("格式化").font(DS.font.caption)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
            .disabled(kind != .json || isTextBlank)
            .help("按 2 空格缩进重排 JSON")

            Button {
                store.updateBuffer(tabID: session.id) { $0.body.text = "" }
            } label: {
                AppIcon(symbol: "xmark.circle", size: 11, tint: DS.color.textSecondary)
            }
            .buttonStyle(IconButtonStyle(size: 24, tint: DS.color.textSecondary, hoverTint: DS.color.danger))
            .disabled(kind == .none || text.isEmpty)
            .help("清空请求体")
        }
        .task(id: ValidationInput(kind: kind, text: text)) { await validateJSON() }
    }

    /// 校验在输入停顿后于后台做一次：每次刷新都同步解析整段正文会明显拖慢输入。
    private func validateJSON() async {
        guard kind == .json, !isTextBlank else {
            session.bodyValidation = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let source = text
        let valid = await Task.detached { JSONValueParser.parse(source) != nil }.value
        guard !Task.isCancelled else { return }
        session.bodyValidation = valid
    }

    /// 校验结果。图标带一个词，光看绿勾不知道它在说哪件事。
    @ViewBuilder
    private var validationChip: some View {
        if let isValid = session.bodyValidation {
            HStack(spacing: DS.space.xs) {
                AppIcon(
                    symbol: isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    size: 10,
                    tint: isValid ? DS.color.success : DS.color.warning
                )
                Text(isValid ? "合法" : "有误")
                    .font(DS.font.caption)
                    .foregroundStyle(isValid ? DS.color.success : DS.color.warning)
            }
            .padding(.horizontal, DS.space.sm)
            .padding(.vertical, 1.5)
            .background(isValid ? DS.color.successSoft : DS.color.warningSoft, in: Capsule())
            .help(isValid ? "JSON 合法" : "JSON 格式有误，发送时仍会按原文发出")
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .animation(DS.motion.select, value: isValid)
        }
    }

    private var kindBinding: Binding<RequestBodyKind> {
        Binding(
            get: { kind },
            set: { newValue in
                store.updateBuffer(tabID: session.id) { $0.body.kind = newValue }
            }
        )
    }

    private func format() {
        guard let value = JSONValueParser.parse(text) else {
            store.setNotice("JSON 格式有误，无法格式化", level: .error)
            return
        }
        store.updateBuffer(tabID: session.id) { $0.body.text = value.prettyPrinted() }
        // 整段被重排了，旧的光标位置已经没有意义：清掉记忆，定位到正文起点。
        session.bodyAnchors.removeValue(forKey: "body-\(kind.rawValue)")
        session.bodyLocateToken += 1
        store.setNotice("已格式化 JSON")
    }
}
