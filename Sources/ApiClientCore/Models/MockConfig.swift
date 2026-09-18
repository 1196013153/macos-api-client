import Foundation

// MARK: - 全局 Mock 策略

/// Mock 的生效范围，设置里可切换。
public enum MockMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 完全关闭：即使接口勾了 Mock 也走真实网络（用来一键「我要打真接口」）。
    case off
    /// 按接口自己的开关（默认）：想做 Mock 的接口在请求编辑器里打开即可。
    case perRequest
    /// 所有请求都走 Mock：断网 / 后端未就绪时整体联调用。
    case always

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "关闭"
        case .perRequest: return "按接口"
        case .always: return "全量"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "所有请求都发真实网络，接口上的 Mock 开关不生效"
        case .perRequest: return "只有勾选了 Mock 的接口返回模拟数据"
        case .always: return "所有请求都返回模拟数据，不发真实网络"
        }
    }
}

// MARK: - 单个接口的 Mock 配置

/// 单个接口的 Mock 配置。
///
/// Mock 解决的是「后端还没好 / 服务起不来，前端也要能把链路跑通」：
/// 命中 Mock 时不会发出真实网络请求，响应由 `MockEngine` 按请求方法 +
/// 请求体方式生成，也可以在界面里手写覆盖。
public struct MockConfig: Codable, Hashable, Sendable {

    /// 该接口是否启用 Mock。全局设置里把 Mock 整体关掉时，这里为 true 也不生效。
    public var isEnabled: Bool
    public var statusCode: Int
    /// 模拟延迟（毫秒）。用来验证前端的 loading / 超时分支。
    public var delayMs: Int
    /// 手写响应体，按请求体方式分别保存（json / raw / formURLEncoded 各一份）。
    /// 某一种方式为空 = 交给 `MockEngine` 按请求自动生成。
    public var bodies: [String: String]
    /// 额外响应头，覆盖自动生成的同名头。
    public var headers: [KeyValueItem]

    public init(
        isEnabled: Bool = false,
        statusCode: Int = 200,
        delayMs: Int = 0,
        bodies: [String: String] = [:],
        headers: [KeyValueItem] = []
    ) {
        self.isEnabled = isEnabled
        self.statusCode = statusCode
        self.delayMs = delayMs
        self.bodies = bodies
        self.headers = headers
    }

    // MARK: 响应体

    public func customBody(for kind: RequestBodyKind) -> String {
        bodies[kind.rawValue] ?? ""
    }

    public mutating func setCustomBody(_ text: String, for kind: RequestBodyKind) {
        if text.isEmpty {
            bodies.removeValue(forKey: kind.rawValue)
        } else {
            bodies[kind.rawValue] = text
        }
    }

    /// 该方式是否已经有手写响应体（空字符串视为「没有」）。
    public func hasCustomBody(for kind: RequestBodyKind) -> Bool {
        !customBody(for: kind).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 响应体编辑器默认停在哪一种方式：跟随请求体方式，无请求体时看 JSON。
    public var editingKind: RequestBodyKind {
        let kinds = RequestBodyKind.allCases.filter { $0 != .none }
        return kinds.first { hasCustomBody(for: $0) } ?? .json
    }

    /// 有没有任何手写内容（界面据此提示「当前按请求自动生成」）。
    public var hasAnyCustomBody: Bool {
        RequestBodyKind.allCases.contains { hasCustomBody(for: $0) }
    }

    public var delaySeconds: TimeInterval {
        TimeInterval(max(0, delayMs)) / 1000
    }

    // MARK: 状态码预设

    /// 下拉里给出的常用状态码。
    public static let presetStatusCodes: [Int] = [200, 201, 202, 204, 400, 401, 403, 404, 409, 500, 502, 503]

    /// 系统给的是本地化小写文案（`not found`），首字母大写一下更好看；
    /// 200 在系统里叫 `no error`，界面上显示成 OK 更符合直觉。
    public static func statusText(for code: Int) -> String {
        if code == 200 { return "OK" }
        let text = HTTPURLResponse.localizedString(forStatusCode: code)
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// 是否算「错误响应」——Mock 也支持造 4xx/5xx 来验证前端异常分支。
    public var isErrorStatus: Bool { !(200..<400).contains(statusCode) }
}
