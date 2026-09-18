import AppKit
import SwiftUI
import ApiClientCore

/// form-data 编辑器。
///
/// 和普通键值表格的区别只有一处，但很关键：**值可以是文件**。
/// 文件字段的状态有四种，界面必须都能一眼看出来：
/// 未选择 / 已选择 / 文件已被移走（红）/ 已勾选但不参与发送（整行降透明度）。
struct FormDataEditor: View {
    @Binding var items: [KeyValueItem]

    private var widths: FormDataRow.Widths { FormDataRow.Widths() }

    /// 勾选生效、但文件没选或已经不在了的字段。
    private var brokenFiles: [KeyValueItem] {
        items.filter { $0.isEnabled && $0.isFile && !$0.fileExists }
    }

    private var fileCount: Int {
        items.activeItems.filter(\.isFile).filter(\.fileExists).count
    }

    var body: some View {
        VStack(spacing: 0) {
            if !brokenFiles.isEmpty {
                warningBar
                hairline
            }

            header
            hairline

            if items.isEmpty {
                emptyArea
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($items) { $item in
                            FormDataRow(
                                item: $item,
                                widths: widths,
                                onDelete: { delete($item.wrappedValue) }
                            )
                        }
                    }
                    .padding(.vertical, DS.space.xs)
                }
            }

            hairline
            addBar
        }
        .background(DS.color.sunken)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.color.hairline)
            .frame(height: 1)
    }

    private var warningBar: some View {
        HStack(spacing: DS.space.sm) {
            AppIcon(symbol: "exclamationmark.triangle.fill", size: 10, tint: DS.color.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(brokenFiles.count) 个文件字段还不能发送")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textPrimary)
                Text("未选择文件，或文件已被移动 / 删除。点对应行的值区域重新选择。")
                    .font(DS.font.micro)
                    .foregroundStyle(DS.color.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.space.lg)
        .padding(.vertical, DS.space.sm)
        .background(DS.color.dangerSoft)
    }

    private var header: some View {
        HStack(spacing: DS.space.sm) {
            Color.clear.frame(width: widths.checkbox, height: 1)
            Text("字段名").frame(width: widths.key, alignment: .leading)
            Text("类型").frame(width: widths.kind, alignment: .leading)
            Text("值 / 文件").frame(maxWidth: .infinity, alignment: .leading)
            Text("备注").frame(width: widths.note, alignment: .leading)
            Color.clear.frame(width: widths.delete, height: 1)
        }
        .font(DS.font.micro)
        .foregroundStyle(DS.color.textTertiary)
        .padding(.horizontal, DS.space.lg)
        .frame(height: 26)
        .background(DS.color.surface)
    }

    private var emptyArea: some View {
        VStack(spacing: DS.space.md) {
            AppIcon(symbol: "paperclip", size: 20, weight: .light, tint: DS.color.textTertiary)
            Text("还没有字段")
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
            HStack(spacing: DS.space.md) {
                Button("添加文本字段") { items.append(KeyValueItem()) }
                    .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
                Button("添加文件字段") { items.append(KeyValueItem(valueKind: .file)) }
                    .buttonStyle(AppButtonStyle(kind: .normal, size: .small))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space.xxl)
        .background(
            RoundedRectangle(cornerRadius: DS.radius.md, style: .continuous)
                .strokeBorder(DS.color.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .padding(DS.space.lg)
        )
    }

    private var addBar: some View {
        HStack(spacing: DS.space.md) {
            Button {
                items.append(KeyValueItem())
            } label: {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "plus", size: 9, weight: .bold, tint: DS.color.brand)
                    Text("添加文本字段").font(DS.font.caption)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))

            Button {
                items.append(KeyValueItem(valueKind: .file))
            } label: {
                HStack(spacing: DS.space.xs) {
                    AppIcon(symbol: "paperclip", size: 9, weight: .bold, tint: DS.color.textSecondary)
                    Text("添加文件").font(DS.font.caption)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .normal, size: .small))

            Spacer(minLength: 0)

            let active = items.activeItems.count
            HStack(spacing: DS.space.sm) {
                Circle()
                    .fill(active > 0 ? DS.color.success : DS.color.textTertiary)
                    .frame(width: 5, height: 5)
                Text("\(active) 项生效" + (fileCount > 0 ? " · \(fileCount) 个文件" : ""))
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
                if let total = totalSizeText {
                    Text(total)
                        .font(DS.font.monoTiny)
                        .foregroundStyle(DS.color.textTertiary)
                }
            }
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: 32)
        .background(DS.color.surface)
    }

    private var totalSizeText: String? {
        let total = items.activeItems.totalFileSize
        guard total > 0 else { return nil }
        return "合计 " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func delete(_ target: KeyValueItem) {
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return }
        items.remove(at: index)
    }
}

// MARK: - 单行

struct FormDataRow: View {
    struct Widths {
        var checkbox: CGFloat = 24
        var key: CGFloat = 168
        var kind: CGFloat = 88
        var note: CGFloat = 132
        var delete: CGFloat = 22
    }

    @Binding var item: KeyValueItem
    let widths: Widths
    let onDelete: () -> Void

    @State private var isHovering = false
    @FocusState private var focused: Field?

    enum Field: Hashable {
        case key
        case value
        case note
    }

    var body: some View {
        HStack(spacing: DS.space.sm) {
            Toggle("", isOn: $item.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .frame(width: widths.checkbox)
                .help(item.isEnabled ? "取消勾选后该字段不参与发送" : "勾选后参与发送")

            field(text: $item.key, placeholder: "字段名", field: .key)
                .frame(width: widths.key)

            kindPicker

            valueCell

            field(text: $item.note, placeholder: "备注", field: .note, monospaced: false)
                .frame(width: widths.note)

            deleteButton
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: DS.metric.kvRow + 4)
        .background(isHovering ? DS.color.rowHover : Color.clear)
        .opacity(item.isEnabled ? 1 : 0.42)
        .onHover { isHovering = $0 }
        .animation(DS.motion.hover, value: isHovering)
        .animation(DS.motion.select, value: item.isEnabled)
    }

    // MARK: 类型

    private var kindPicker: some View {
        Picker("", selection: $item.valueKind) {
            ForEach(KeyValueKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.mini)
        .frame(width: widths.kind)
        .help("文本：直接发字符串；文件：把本地文件作为这个字段的内容")
    }

    // MARK: 值

    @ViewBuilder
    private var valueCell: some View {
        if item.isFile {
            fileCell
        } else {
            field(text: $item.value, placeholder: "值，支持 {{变量}}", field: .value)
        }
    }

    private var fileCell: some View {
        let exists = item.fileExists
        let chosen = !item.filePath.isEmpty

        return Button {
            chooseFile()
        } label: {
            HStack(spacing: DS.space.sm) {
                AppIcon(
                    symbol: chosen ? (exists ? "doc.fill" : "exclamationmark.triangle.fill") : "paperclip",
                    size: 10,
                    tint: chosen ? (exists ? DS.color.brand : DS.color.danger) : DS.color.textTertiary
                )

                if let name = item.fileName {
                    Text(name)
                        .font(DS.font.monoSmall)
                        .foregroundStyle(exists ? DS.color.textPrimary : DS.color.danger)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if exists, let size = item.fileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(DS.font.monoTiny)
                            .foregroundStyle(DS.color.textTertiary)
                    } else {
                        Text("文件已不存在")
                            .font(DS.font.micro)
                            .foregroundStyle(DS.color.danger)
                    }
                } else {
                    Text("选择文件…")
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textSecondary)
                }

                Spacer(minLength: DS.space.sm)

                Text(chosen ? "重新选择" : "")
                    .font(DS.font.micro)
                    .foregroundStyle(DS.color.textTertiary)
            }
            .padding(.horizontal, DS.space.sm)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(focused == .value ? DS.color.fieldFocused : DS.color.field)
            .overlay(
                RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
                    .strokeBorder(chosen && !exists ? DS.color.danger.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chosen ? item.filePath : "点击选择本地文件")
    }

    private func chooseFile() {
        let label = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = FileDialogs.openUploadFile(
            message: "为字段「\(label.isEmpty ? "未命名" : label)」选择要上传的文件"
        ) else { return }
        item.value = url.path
        item.valueKind = .file
    }

    // MARK: 通用输入框

    private func field(
        text: Binding<String>,
        placeholder: String,
        field: Field,
        monospaced: Bool = true
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? DS.font.monoSmall : DS.font.caption)
            .foregroundStyle(field == .note ? DS.color.textSecondary : DS.color.textPrimary)
            .padding(.horizontal, DS.space.sm)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(focused == field ? DS.color.fieldFocused : DS.color.field)
            .overlay(
                RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
                    .strokeBorder(focused == field ? DS.color.brand : Color.clear, lineWidth: 1)
            )
            .focused($focused, equals: field)
            .animation(DS.motion.hover, value: focused)
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            AppIcon(
                symbol: "minus.circle.fill",
                size: 11,
                tint: isHovering ? DS.color.danger : DS.color.textTertiary
            )
        }
        .buttonStyle(IconButtonStyle(size: 20, tint: DS.color.textTertiary, hoverTint: DS.color.danger))
        .frame(width: widths.delete)
        .opacity(isHovering ? 1 : 0.3)
        .help("删除这一行")
    }
}
