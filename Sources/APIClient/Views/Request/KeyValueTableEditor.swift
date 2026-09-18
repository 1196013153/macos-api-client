import SwiftUI
import ApiClientCore

/// 通用键值表格编辑器：参数 / 请求头 / 表单字段 / 环境变量共用。
struct KeyValueTableEditor: View {
    @Binding var items: [KeyValueItem]
    var showsLocation: Bool = false
    var keyPlaceholder: String = "名称"
    var valuePlaceholder: String = "值"
    var addTitle: String = "添加"
    var emptyTitle: String = "还没有内容"

    private var widths: KeyValueRow.Widths { KeyValueRow.Widths() }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            if items.isEmpty {
                emptyArea
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, _ in
                            KeyValueRow(
                                item: $items[index],
                                showsLocation: showsLocation,
                                widths: widths,
                                keyPlaceholder: keyPlaceholder,
                                valuePlaceholder: valuePlaceholder,
                                isZebra: index % 2 == 1,
                                onDelete: { delete(items[index]) }
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

    private var header: some View {
        HStack(spacing: DS.space.sm) {
            Color.clear.frame(width: widths.checkbox, height: 1)
            Text(keyPlaceholder).frame(width: widths.key, alignment: .leading)
            Text(valuePlaceholder).frame(maxWidth: .infinity, alignment: .leading)
            if showsLocation {
                Text("位置").frame(width: widths.location, alignment: .leading)
            }
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
            AppIcon(symbol: "plus.rectangle.on.rectangle", size: 20, weight: .light, tint: DS.color.textTertiary)
            Text(emptyTitle)
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
            Button(addTitle) { items.append(KeyValueItem()) }
                .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
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
                    Text(addTitle)
                        .font(DS.font.caption)
                }
            }
            .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))

            Spacer(minLength: 0)

            let active = items.activeItems.count
            HStack(spacing: DS.space.xs) {
                Circle()
                    .fill(active > 0 ? DS.color.success : DS.color.textTertiary)
                    .frame(width: 5, height: 5)
                Text("\(active) 项生效 / 共 \(items.count) 行")
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
            }
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: 32)
        .background(DS.color.surface)
    }

    private func delete(_ target: KeyValueItem) {
        guard let index = items.firstIndex(where: { $0.id == target.id }) else { return }
        items.remove(at: index)
    }
}

// MARK: - 单行

struct KeyValueRow: View {
    struct Widths {
        var checkbox: CGFloat = 24
        var key: CGFloat = 186
        var location: CGFloat = 82
        var note: CGFloat = 132
        var delete: CGFloat = 22
    }

    @Binding var item: KeyValueItem
    let showsLocation: Bool
    let widths: Widths
    let keyPlaceholder: String
    let valuePlaceholder: String
    var isZebra: Bool = false
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
                .help(item.isEnabled ? "取消勾选后该行不参与发送" : "勾选后参与发送")

            field(text: $item.key, placeholder: keyPlaceholder, field: .key, monospaced: true)
                .frame(width: widths.key)

            field(text: $item.value, placeholder: valuePlaceholder, field: .value, monospaced: true)

            if showsLocation {
                locationPicker
            }

            field(text: $item.note, placeholder: "备注", field: .note, monospaced: false)
                .frame(width: widths.note)

            deleteButton
        }
        .padding(.horizontal, DS.space.lg)
        .frame(height: DS.metric.kvRow)
        .background(rowBackground)
        .opacity(item.isEnabled ? 1 : 0.42)
        .onHover { isHovering = $0 }
        .animation(DS.motion.hover, value: isHovering)
        .animation(DS.motion.select, value: item.isEnabled)
    }

    private func field(
        text: Binding<String>,
        placeholder: String,
        field: Field,
        monospaced: Bool
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? DS.font.monoSmall : DS.font.caption)
            .foregroundStyle(field == .note ? DS.color.textSecondary : DS.color.textPrimary)
            .padding(.horizontal, DS.space.sm)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .background(fieldBackground(for: field))
            .overlay(fieldBorder(for: field))
            .focused($focused, equals: field)
            .animation(DS.motion.hover, value: focused)
    }

    private var locationPicker: some View {
        HStack(spacing: DS.space.xs) {
            Circle()
                .fill(locationTint)
                .frame(width: 5, height: 5)

            Picker("", selection: $item.location) {
                ForEach(ParamLocation.allCases) { location in
                    Text(location.title).tag(location)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.mini)
            .frame(width: widths.location - 12)
        }
        .frame(width: widths.location, alignment: .leading)
        .help("参数位置：query 拼在地址后，path 替换 :占位符，header 作为请求头发送")
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            AppIcon(symbol: "minus.circle.fill", size: 11, tint: isHovering ? DS.color.danger : DS.color.textTertiary)
        }
        .buttonStyle(IconButtonStyle(size: 20, tint: DS.color.textTertiary, hoverTint: DS.color.danger))
        .frame(width: widths.delete)
        .opacity(isHovering ? 1 : 0.3)
        .help("删除这一行")
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isHovering {
            DS.color.rowHover
        } else if isZebra {
            DS.color.zebra
        } else {
            Color.clear
        }
    }

    private func fieldBackground(for field: Field) -> Color {
        focused == field ? DS.color.fieldFocused : DS.color.field
    }

    @ViewBuilder
    private func fieldBorder(for field: Field) -> some View {
        RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
            .strokeBorder(focused == field ? DS.color.brand : Color.clear, lineWidth: 1)
    }

    private var locationTint: Color {
        switch item.location {
        case .query: return DS.color.brand
        case .path: return DS.color.warning
        case .header: return DS.color.info
        }
    }
}
