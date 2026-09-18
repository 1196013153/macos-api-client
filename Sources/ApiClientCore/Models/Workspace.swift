import Foundation

// MARK: - 标签页引用（持久化部分）

/// 标签页只持久化「指向哪个项目 / 哪个接口」，编辑缓冲与响应属于运行时状态。
public struct TabRef: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: UUID
    /// nil 表示草稿标签（尚未保存为正式接口）。
    public var requestID: UUID?

    public init(id: UUID = UUID(), projectID: UUID, requestID: UUID? = nil) {
        self.id = id
        self.projectID = projectID
        self.requestID = requestID
    }
}

// MARK: - 设置

/// 应用外观：system 跟随系统，light / dark 固定
public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    /// 应用外观（跟随系统 / 浅色 / 深色）
    public var appearance: AppAppearance
    public var requestTimeout: TimeInterval
    public var verifyTLS: Bool
    public var followRedirects: Bool
    /// Mock 生效范围，默认「按接口」——能力开箱即用，但不会悄悄替掉真实请求。
    public var mockMode: MockMode

    public init(
        appearance: AppAppearance = .system,
        requestTimeout: TimeInterval = 30,
        verifyTLS: Bool = true,
        followRedirects: Bool = true,
        mockMode: MockMode = .perRequest
    ) {
        self.appearance = appearance
        self.requestTimeout = requestTimeout
        self.verifyTLS = verifyTLS
        self.followRedirects = followRedirects
        self.mockMode = mockMode
    }

    // 设置项会随版本增删，缺字段时回落默认值而不是解码失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        requestTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 30
        verifyTLS = try container.decodeIfPresent(Bool.self, forKey: .verifyTLS) ?? true
        followRedirects = try container.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? true
        mockMode = try container.decodeIfPresent(MockMode.self, forKey: .mockMode) ?? .perRequest
    }

    /// 这次发送是否走 Mock。
    public func shouldMock(_ request: APIRequest) -> Bool {
        switch mockMode {
        case .off: return false
        case .always: return true
        case .perRequest: return request.mock.isEnabled
        }
    }
}

// MARK: - 工作区状态

public struct WorkspaceState: Codable, Sendable {
    /// v3：文件夹折叠状态从项目文件挪到这里（`collapsedFolderIDs`）。
    public static let currentVersion = 3

    public var version: Int
    public var activeProjectID: UUID?
    public var openTabs: [TabRef]
    /// 每个项目各自停在哪个标签上（key 是项目 id 的 uuidString）。
    /// 标签页按项目隔离后，切项目要回到该项目上次所在的标签，而不是全局最后一个。
    public var activeTabs: [String: UUID]
    /// v1 的全局活动标签，仅用于向后兼容读取。
    public var activeTabID: UUID?
    /// 折叠中的文件夹（节点 id 全局唯一，不必按项目分组）。展开 / 折叠只改这个轻量文件，
    /// 不再把上 MB 的项目文件整个重写一遍。
    public var collapsedFolderIDs: [UUID]
    public var settings: AppSettings

    public init(
        version: Int = WorkspaceState.currentVersion,
        activeProjectID: UUID? = nil,
        openTabs: [TabRef] = [],
        activeTabs: [String: UUID] = [:],
        activeTabID: UUID? = nil,
        collapsedFolderIDs: [UUID] = [],
        settings: AppSettings = AppSettings()
    ) {
        self.version = version
        self.activeProjectID = activeProjectID
        self.openTabs = openTabs
        self.activeTabs = activeTabs
        self.activeTabID = activeTabID
        self.collapsedFolderIDs = collapsedFolderIDs
        self.settings = settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? WorkspaceState.currentVersion
        activeProjectID = try container.decodeIfPresent(UUID.self, forKey: .activeProjectID)
        openTabs = try container.decodeIfPresent([TabRef].self, forKey: .openTabs) ?? []
        activeTabs = try container.decodeIfPresent([String: UUID].self, forKey: .activeTabs) ?? [:]
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        collapsedFolderIDs = try container.decodeIfPresent([UUID].self, forKey: .collapsedFolderIDs) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()

        // v1 只有全局活动标签：把它算到对应项目头上，老工作区不会丢「上次停在哪个标签」。
        if activeTabs.isEmpty, let legacy = activeTabID,
           let tab = openTabs.first(where: { $0.id == legacy }) {
            activeTabs[tab.projectID.uuidString] = legacy
        }
    }

    public func activeTab(for projectID: UUID) -> UUID? {
        activeTabs[projectID.uuidString]
    }
}
