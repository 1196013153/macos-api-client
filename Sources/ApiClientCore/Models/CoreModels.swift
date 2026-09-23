import Foundation

// MARK: - HTTP 方法

public enum HTTPMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    public var id: String { rawValue }

    /// GET / HEAD 默认不携带请求体，界面据此决定 Body 分区是否默认展开。
    public var allowsBody: Bool {
        switch self {
        case .get, .head: return false
        default: return true
        }
    }
}

// MARK: - 键值对（Params / Headers / 表单 / 变量通用）

/// 参数位置。`path` 用于替换 URL 中的 `:name` 或 `{name}` 占位符。
public enum ParamLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case query
    case path
    case header

    public var id: String { rawValue }
}

/// 键值对的值类型。目前只有 form-data 会用到 `.file`：
/// 此时 `value` 存的是本地文件的绝对路径。
public enum KeyValueKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text
    case file

    public var id: String { rawValue }

    public var title: String { self == .text ? "文本" : "文件" }
}

public struct KeyValueItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var key: String
    /// 文本行的值，或文件行的本地绝对路径。
    public var value: String
    public var note: String
    public var location: ParamLocation
    public var valueKind: KeyValueKind

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        key: String = "",
        value: String = "",
        note: String = "",
        location: ParamLocation = .query,
        valueKind: KeyValueKind = .text
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.key = key
        self.value = value
        self.note = note
        self.location = location
        self.valueKind = valueKind
    }

    // `valueKind` 是后加的字段：老项目文件里没有它，缺字段必须回落默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        location = try container.decodeIfPresent(ParamLocation.self, forKey: .location) ?? .query
        valueKind = try container.decodeIfPresent(KeyValueKind.self, forKey: .valueKind) ?? .text
    }

    /// 空行（界面上的“占位行”）在发送时会被过滤掉。
    public var isBlank: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var activeKey: String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return isEnabled && !trimmed.isEmpty ? trimmed : nil
    }

    // MARK: 文件字段

    public var isFile: Bool { valueKind == .file }

    /// 文件行的本地路径（已去空白）。
    public var filePath: String {
        isFile ? value.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    public var fileName: String? {
        let path = filePath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// 文件是否真的还在。发送前的界面提示与发送时的报错都看它。
    public var fileExists: Bool {
        guard isFile, !filePath.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    public var fileSize: Int64? {
        guard fileExists else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

public extension Array where Element == KeyValueItem {
    /// 文件行里选好且存在的文件总大小。
    var totalFileSize: Int64 {
        reduce(0) { $0 + (($1.isEnabled && $1.isFile) ? ($1.fileSize ?? 0) : 0) }
    }
}

public extension Array where Element == KeyValueItem {
    /// 发送时真正生效的条目：启用 + key 非空。
    var activeItems: [KeyValueItem] {
        filter { $0.activeKey != nil }
    }

    func items(at location: ParamLocation) -> [KeyValueItem] {
        filter { $0.location == location }
    }

    /// 展开为字典，后写的同名 key 覆盖先写的。
    var asDictionary: [String: String] {
        var result: [String: String] = [:]
        for item in activeItems {
            guard let key = item.activeKey else { continue }
            result[key] = item.value
        }
        return result
    }
}

// MARK: - 请求体

public enum RequestBodyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case json
    case raw
    case formURLEncoded
    /// `multipart/form-data`：字段可以是文本，也可以是本地文件。
    case formData

    public var id: String { rawValue }

    public var defaultContentType: String? {
        switch self {
        case .none: return nil
        case .json: return "application/json"
        case .raw: return "text/plain"
        case .formURLEncoded: return "application/x-www-form-urlencoded"
        // multipart 的 Content-Type 必须带 boundary，只能等编码时才知道。
        case .formData: return nil
        }
    }

    /// 是否需要按 multipart 编码。
    public var isMultipart: Bool { self == .formData }
}

public struct RequestBody: Codable, Hashable, Sendable {
    public var kind: RequestBodyKind
    /// json / raw 模式下的原文。
    public var text: String
    /// formURLEncoded 模式下的字段。
    public var fields: [KeyValueItem]

    public init(kind: RequestBodyKind = .none, text: String = "", fields: [KeyValueItem] = []) {
        self.kind = kind
        self.text = text
        self.fields = fields
    }
}

// MARK: - 接口请求

public struct APIRequest: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var method: HTTPMethod
    /// 支持 `{{变量}}` 与 `:pathParam` 占位；可以是相对路径（拼环境 baseURL）。
    public var url: String
    public var params: [KeyValueItem]
    public var headers: [KeyValueItem]
    public var body: RequestBody
    /// 该接口的 Mock 配置（状态码 / 延迟 / 分方式的响应体）。
    public var mock: MockConfig
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Java 项目同步生成的接口来源标记（文件#类#方法）。手工接口保持 nil。
    public var sourceKey: String?

    public init(
        id: UUID = UUID(),
        name: String = "新建请求",
        method: HTTPMethod = .get,
        url: String = "",
        params: [KeyValueItem] = [],
        headers: [KeyValueItem] = [],
        body: RequestBody = RequestBody(),
        mock: MockConfig = MockConfig(),
        note: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.params = params
        self.headers = headers
        self.body = body
        self.mock = mock
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceKey = sourceKey
    }

    // `mock` 是后加的字段：老项目文件里没有它，必须回落默认值而不是解码失败
    // （磁盘上已经有 2000+ 个接口，不能因为一个新增字段读不出来）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名请求"
        method = try container.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        params = try container.decodeIfPresent([KeyValueItem].self, forKey: .params) ?? []
        headers = try container.decodeIfPresent([KeyValueItem].self, forKey: .headers) ?? []
        body = try container.decodeIfPresent(RequestBody.self, forKey: .body) ?? RequestBody()
        mock = try container.decodeIfPresent(MockConfig.self, forKey: .mock) ?? MockConfig()
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        sourceKey = try container.decodeIfPresent(String.self, forKey: .sourceKey)
    }

    /// 全新草稿：带一行空 Header，符合“新建就要能直接写”的直觉。
    public static func newDraft(name: String = "新建请求") -> APIRequest {
        APIRequest(
            name: name,
            method: .get,
            url: "",
            params: [KeyValueItem()],
            headers: [KeyValueItem()]
        )
    }

    public var queryParams: [KeyValueItem] { params.items(at: .query) }
    public var pathParams: [KeyValueItem] { params.items(at: .path) }

    /// 是否有未保存意义的内容（用于草稿标签的脏标记判断）。
    public var hasContent: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !params.activeItems.isEmpty
            || !headers.activeItems.isEmpty
            || body.kind != .none
    }
}
