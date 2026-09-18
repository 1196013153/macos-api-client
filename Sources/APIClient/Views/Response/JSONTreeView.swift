import AppKit
import SwiftUI
import ApiClientCore

/// 保序 JSON 树形查看器。
///
/// 先把树按展开状态扁平化成「可见行」，再交给一个 `LazyVStack` 渲染——和侧边栏集合树同一思路。
/// 之前是每个节点一个嵌套视图、子树整体同步构建，「展开全部」遇到几千个节点会卡住几秒；
/// 扁平化后只有滚进视野的行会被创建，展开状态也只是一个集合，切换时重算一次行列表即可。
struct JSONTreeView: View {
    @Environment(AppStore.self) private var store

    let value: JSONValue
    var expandDepth: Int = 2
    /// 字段名 / 值的筛选词：非空时只显示命中的节点及其祖先路径，命中路径全部展开。
    var filter: String = ""

    @State private var rows: [JSONTreeRow]
    /// 用户手动切换过的节点（相对「默认展开深度」取反）。换展开深度时清空。
    @State private var toggled: Set<String> = []

    init(value: JSONValue, expandDepth: Int = 2, filter: String = "") {
        self.value = value
        self.expandDepth = expandDepth
        self.filter = filter
        _rows = State(initialValue: JSONTreeFlattener.rows(value, expandDepth: expandDepth, toggled: [], filter: filter))
    }

    var body: some View {
        // 横向 ScrollView 在内容宽度小于视口时会把内容居中，
        // 所以用 GeometryReader 把内容宽度顶到视口宽度，保证靠左对齐。
        GeometryReader { geometry in
            if rows.isEmpty {
                EmptyState(
                    art: .search,
                    title: "没有匹配「\(filter)」的字段",
                    subtitle: "按字段名或值筛选，不区分大小写"
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            JSONTreeRowView(row: row, onToggle: { toggle(row.id) }, onCopyNode: { copyNode(row) })
                        }
                    }
                    .padding(.vertical, DS.space.md)
                    .padding(.horizontal, DS.space.md)
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
            }
        }
        .background(DS.color.sunken)
        .onChange(of: expandDepth) { _, _ in
            toggled = []
            rebuild()
        }
        .task(id: filter) {
            // 大响应逐键重算会跟不上输入，停顿一下再算；首次（空筛选）已在 init 里算过。
            if !filter.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            rebuild()
        }
    }

    private func toggle(_ id: String) {
        if toggled.contains(id) {
            toggled.remove(id)
        } else {
            toggled.insert(id)
        }
        rebuild()
    }

    private func rebuild() {
        rows = JSONTreeFlattener.rows(value, expandDepth: expandDepth, toggled: toggled, filter: filter)
    }

    /// 复制整个节点的 JSON（容器）。行里不持有子树，按索引路径回到原值上取。
    private func copyNode(_ row: JSONTreeRow) {
        guard let node = JSONTreeFlattener.node(in: value, at: row.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.prettyPrinted(), forType: .string)
        store.setNotice("已复制 \(row.keyPath) 的 JSON")
    }
}

// MARK: - 可见行

/// 树的一行。只放展示用的字符串，不持有子树：行列表在每次展开 / 折叠后整体重算，
/// SwiftUI 按行做 diff 时比较的就是这些字段，持有子树会让比较成本随响应体大小增长。
struct JSONTreeRow: Identifiable, Hashable {
    enum ValueKind: Hashable {
        case object
        case array
        case null
        case bool
        case number
        case string
    }

    /// 节点的索引路径（如 `0/3/12`），闭合行在末尾加 `/end`。
    let id: String
    /// 可读的字段路径（`$.data.items[0].name`），复制路径用。
    let keyPath: String
    let level: Int
    /// 字段名（对象成员）。
    let key: String?
    /// 数组下标（数组元素）。
    let index: Int?
    let kind: ValueKind
    /// 行内展示的值：叶子是值本身，容器是起始括号或闭合括号。
    let text: String
    /// 折叠的容器显示的摘要（`{3 个字段}` / `[5 项]`）。
    let summary: String?
    let hasChildren: Bool
    let isExpanded: Bool
    /// 容器的闭合括号行。
    let isClosing: Bool
    /// 叶子的原始值（复制按钮用；字符串不带引号）。
    let copyText: String?
}

enum JSONTreeFlattener {
    static func rows(_ value: JSONValue, expandDepth: Int, toggled: Set<String>, filter: String = "") -> [JSONTreeRow] {
        var rows: [JSONTreeRow] = []
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            append(value, key: nil, index: nil, path: "0", keyPath: "$", level: 0, expandDepth: expandDepth, toggled: toggled, into: &rows)
        } else {
            _ = appendFiltered(value, key: nil, index: nil, path: "0", keyPath: "$", level: 0, query: query, toggled: toggled, into: &rows)
        }
        return rows
    }

    /// 按行的索引路径（`0/3/12`）回到原值上取子树。
    static func node(in root: JSONValue, at path: String) -> JSONValue? {
        var current = root
        for component in path.split(separator: "/").dropFirst() {
            guard let offset = Int(component) else { return nil }
            switch current {
            case .object(let entries) where offset < entries.count: current = entries[offset].value
            case .array(let items) where offset < items.count: current = items[offset]
            default: return nil
            }
        }
        return current
    }

    private static func append(
        _ value: JSONValue,
        key: String?,
        index: Int?,
        path: String,
        keyPath: String,
        level: Int,
        expandDepth: Int,
        toggled: Set<String>,
        into rows: inout [JSONTreeRow]
    ) {
        let hasChildren = value.isContainer && value.childCount > 0
        let isExpanded = hasChildren && ((level < expandDepth) != toggled.contains(path))

        rows.append(nodeRow(value, key: key, index: index, path: path, keyPath: keyPath, level: level, isExpanded: isExpanded))

        guard isExpanded else { return }

        switch value {
        case .object(let entries):
            for (offset, entry) in entries.enumerated() {
                append(
                    entry.value, key: entry.key, index: nil, path: "\(path)/\(offset)",
                    keyPath: keyPath + memberSuffix(key: entry.key), level: level + 1,
                    expandDepth: expandDepth, toggled: toggled, into: &rows
                )
            }
        case .array(let items):
            for (offset, item) in items.enumerated() {
                append(
                    item, key: nil, index: offset, path: "\(path)/\(offset)",
                    keyPath: "\(keyPath)[\(offset)]", level: level + 1,
                    expandDepth: expandDepth, toggled: toggled, into: &rows
                )
            }
        default:
            break
        }

        rows.append(closingRow(value, path: path, keyPath: keyPath, level: level))
    }

    /// 筛选模式：只保留「自身命中」或「后代命中」的节点，命中路径强制展开。
    /// 自身命中但后代都不命中的容器折叠显示摘要，用户点开时按手动切换状态展示完整子树。
    /// 返回该子树是否有命中。
    private static func appendFiltered(
        _ value: JSONValue,
        key: String?,
        index: Int?,
        path: String,
        keyPath: String,
        level: Int,
        query: String,
        toggled: Set<String>,
        into rows: inout [JSONTreeRow]
    ) -> Bool {
        let selfMatched = (key?.lowercased().contains(query) ?? false)
            || (!value.isContainer && JSONTreeText.plainText(value).lowercased().contains(query))

        var childRows: [JSONTreeRow] = []
        var childMatched = false
        switch value {
        case .object(let entries):
            for (offset, entry) in entries.enumerated() where appendFiltered(
                entry.value, key: entry.key, index: nil, path: "\(path)/\(offset)",
                keyPath: keyPath + memberSuffix(key: entry.key), level: level + 1,
                query: query, toggled: toggled, into: &childRows
            ) {
                childMatched = true
            }
        case .array(let items):
            for (offset, item) in items.enumerated() where appendFiltered(
                item, key: nil, index: offset, path: "\(path)/\(offset)",
                keyPath: "\(keyPath)[\(offset)]", level: level + 1,
                query: query, toggled: toggled, into: &childRows
            ) {
                childMatched = true
            }
        default:
            break
        }

        guard selfMatched || childMatched else { return false }

        if childMatched {
            rows.append(nodeRow(value, key: key, index: index, path: path, keyPath: keyPath, level: level, isExpanded: true))
            rows.append(contentsOf: childRows)
            rows.append(closingRow(value, path: path, keyPath: keyPath, level: level))
        } else {
            // 只有自身命中：默认折叠，手动点开后展示完整子树（expandDepth 0 = 只看手动切换）
            append(value, key: key, index: index, path: path, keyPath: keyPath, level: level, expandDepth: 0, toggled: toggled, into: &rows)
        }
        return true
    }

    private static func nodeRow(
        _ value: JSONValue, key: String?, index: Int?, path: String, keyPath: String, level: Int, isExpanded: Bool
    ) -> JSONTreeRow {
        let hasChildren = value.isContainer && value.childCount > 0
        return JSONTreeRow(
            id: path,
            keyPath: keyPath,
            level: level,
            key: key,
            index: index,
            kind: kind(of: value),
            text: openingText(of: value),
            summary: hasChildren && !isExpanded ? value.summary : nil,
            hasChildren: hasChildren,
            isExpanded: isExpanded,
            isClosing: false,
            copyText: value.isContainer ? nil : JSONTreeText.plainText(value)
        )
    }

    private static func closingRow(_ value: JSONValue, path: String, keyPath: String, level: Int) -> JSONTreeRow {
        JSONTreeRow(
            id: "\(path)/end",
            keyPath: keyPath,
            level: level,
            key: nil,
            index: nil,
            kind: kind(of: value),
            text: closingText(of: value),
            summary: nil,
            hasChildren: false,
            isExpanded: false,
            isClosing: true,
            copyText: nil
        )
    }

    /// 对象成员在路径里的写法：普通标识符用 `.key`，含特殊字符的用 `["key"]`。
    private static func memberSuffix(key: String) -> String {
        let isIdentifier = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
            && !(key.first?.isNumber ?? true)
        return isIdentifier ? ".\(key)" : "[\"\(key)\"]"
    }

    private static func kind(of value: JSONValue) -> JSONTreeRow.ValueKind {
        switch value {
        case .object: return .object
        case .array: return .array
        case .null: return .null
        case .bool: return .bool
        case .number: return .number
        case .string: return .string
        }
    }

    private static func openingText(of value: JSONValue) -> String {
        switch value {
        case .object: return "{"
        case .array: return "["
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let literal): return literal
        case .string(let text): return JSONTreeText.quoted(text)
        }
    }

    private static func closingText(of value: JSONValue) -> String {
        switch value {
        case .object: return "}"
        case .array: return "]"
        default: return ""
        }
    }
}

// MARK: - 行视图

struct JSONTreeRowView: View {
    @Environment(AppStore.self) private var store

    let row: JSONTreeRow
    let onToggle: () -> Void
    /// 复制整个容器节点的 JSON（子树不在行里，由树视图按路径取）。
    var onCopyNode: () -> Void = {}

    @State private var isHovering = false

    var body: some View {
        if row.isClosing {
            closingRow
        } else {
            nodeRow
        }
    }

    private var nodeRow: some View {
        HStack(spacing: DS.space.xs) {
            indent

            disclosure

            label

            if row.key != nil || row.index != nil {
                Text(":")
                    .font(DS.font.monoSmall)
                    .foregroundStyle(DS.color.syntaxPunctuation)
            }

            Text(row.text)
                .font(DS.font.monoSmall)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)

            if let summary = row.summary {
                Text(summary)
                    .font(DS.font.monoTiny)
                    .foregroundStyle(DS.color.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(DS.color.field, in: Capsule())
            }

            Spacer(minLength: DS.space.lg)

            if isHovering, let copyText = row.copyText {
                copyButton(copyText)
            }
        }
        .padding(.horizontal, DS.space.sm)
        .frame(height: 20)
        .background(
            RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous)
                .fill(isHovering ? DS.color.rowHover : Color.clear)
        )
        .onHover { isHovering = $0 }
        .animation(DS.motion.hover, value: isHovering)
        .contextMenu {
            if let copyText = row.copyText {
                Button("复制值") { copy(copyText, notice: "已复制值") }
            } else if row.hasChildren {
                Button("复制该节点 JSON", action: onCopyNode)
            }
            if let key = row.key {
                Button("复制字段名") { copy(key, notice: "已复制字段名") }
            }
            Button("复制路径") { copy(row.keyPath, notice: "已复制路径 \(row.keyPath)") }
        }
    }

    private func copy(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.setNotice(notice)
    }

    private var closingRow: some View {
        HStack(spacing: DS.space.xs) {
            Color.clear.frame(width: CGFloat(row.level) * 14 + 12, height: 1)
            Text(row.text)
                .font(DS.font.monoSmall)
                .foregroundStyle(DS.color.syntaxPunctuation)
        }
        .frame(height: 18)
    }

    private var indent: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(row.level, 0), id: \.self) { _ in
                Rectangle()
                    .fill(DS.color.hairline)
                    .frame(width: 1)
                    .padding(.leading, 5)
                    .padding(.trailing, 8)
            }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.hasChildren {
            Button(action: onToggle) {
                AppIcon(symbol: "chevron.right", size: 8, weight: .bold, tint: DS.color.textTertiary)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(DS.motion.select, value: row.isExpanded)
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }

    /// 字段名 / 数组下标。
    @ViewBuilder
    private var label: some View {
        if let key = row.key {
            Text(JSONTreeText.quoted(key))
                .font(DS.font.monoSmall)
                .foregroundStyle(DS.color.syntaxKey)
                .textSelection(.enabled)
        } else if let index = row.index {
            Text("[\(index)]")
                .font(DS.font.monoTiny)
                .foregroundStyle(DS.color.textTertiary)
                .padding(.horizontal, 4)
                .background(DS.color.field, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
        }
    }

    private var valueColor: Color {
        switch row.kind {
        case .object, .array: return DS.color.syntaxPunctuation
        case .null: return DS.color.syntaxNull
        case .bool: return DS.color.syntaxBool
        case .number: return DS.color.syntaxNumber
        case .string: return DS.color.syntaxString
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            AppIcon(symbol: "doc.on.doc", size: 9, tint: DS.color.textTertiary)
        }
        .buttonStyle(IconButtonStyle(size: 16, tint: DS.color.textTertiary))
        .transition(.opacity)
        .help("复制该值")
    }
}

// MARK: - 文本工具

enum JSONTreeText {
    /// 展示用字符串：展开为单行并截断，避免一个字段撑爆横向滚动。
    static func quoted(_ text: String) -> String {
        let singleLine = collapse(text)
        let limit = 400
        if singleLine.count > limit {
            return "\"\(singleLine.prefix(limit))…（共 \(singleLine.count) 字符）\""
        }
        return "\"\(singleLine)\""
    }

    /// 复制的原始值：字符串不带引号，其余保留字面量。
    static func plainText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .number(let literal): return literal
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array, .object: return value.prettyPrinted()
        }
    }

    private static func collapse(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
