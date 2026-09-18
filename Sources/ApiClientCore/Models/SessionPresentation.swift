import Foundation

// MARK: - 请求编辑器分区

/// 请求编辑器的分区。放在核心层是因为「打开标签时停在哪一栏」属于标签页状态，
/// 而标签页状态要能被自检覆盖到。
public enum RequestPane: String, Codable, CaseIterable, Identifiable, Sendable {
    case params
    case headers
    case body
    case mock
    case note

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .params: return "参数"
        case .headers: return "请求头"
        case .body: return "请求体"
        case .mock: return "Mock"
        case .note: return "说明"
        }
    }
}

// MARK: - 响应展示方式

/// 响应面板的分区（响应体 / 响应头 / 请求详情）。
public enum ResponsePane: String, Codable, CaseIterable, Identifiable, Sendable {
    case body
    case headers
    case requestDetail

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .body: return "响应体"
        case .headers: return "响应头"
        case .requestDetail: return "请求详情"
        }
    }
}

public enum ResponseBodyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case tree
    case raw

    public var id: String { rawValue }

    public var title: String { self == .tree ? "树形" : "原文" }
}

// MARK: - 编辑器位置

/// 编辑器在某种请求体方式下的位置（光标 + 滚动）。
///
/// 每个标签、每种请求体方式各自记一份，这样在 JSON / Raw / Form 之间来回切换、
/// 或者在标签之间来回切换时，视线不会被重置回顶部。
public struct BodyEditorAnchor: Hashable, Sendable {
    /// 光标位置（UTF-16 偏移，和 NSTextView 的范围一致）。
    public var caret: Int
    public var selectionLength: Int
    /// 滚动位置（内容坐标 y）。
    public var scrollY: Double

    public init(caret: Int = 0, selectionLength: Int = 0, scrollY: Double = 0) {
        self.caret = caret
        self.selectionLength = selectionLength
        self.scrollY = scrollY
    }
}

/// 纯文本定位：把「自动定位到当前请求方式所在的位置」变成可测的纯函数。
public enum TextLocator {

    /// 正文起点：跳过前导空白与空行后的第一个字符偏移。
    ///
    /// JSON 请求体常见前面带几个空行，直接滚动到第 0 行会让人以为编辑器是空的，
    /// 这里定位到真正有内容的那一行。
    public static func contentStart(in text: String) -> Int {
        let units = Array(text.utf16)
        for (index, unit) in units.enumerated() where !isWhitespace(unit) {
            return index
        }
        return 0
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C: return true
        default: return false
        }
    }

    /// 把越界的光标夹回合法范围（内容被替换后旧位置可能已经不存在）。
    public static func clamp(_ location: Int, in text: String) -> Int {
        let count = text.utf16.count
        return min(max(0, location), count)
    }
}
