import Foundation

// MARK: - 环境

public struct APIEnvironment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// 相对路径请求会拼在这个前缀后面；为空时要求请求本身写完整 URL。
    public var baseURL: String
    public var variables: [KeyValueItem]

    public init(id: UUID = UUID(), name: String, baseURL: String = "", variables: [KeyValueItem] = []) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.variables = variables
    }

    /// 合并后的环境变量（含隐含的 `baseUrl`）。
    public var resolvedVariables: [String: String] {
        var map = variables.asDictionary
        map["baseUrl"] = baseURL
        map["baseURL"] = baseURL
        return map
    }

    public static func `default`() -> APIEnvironment {
        APIEnvironment(name: "默认环境", baseURL: "")
    }
}

// MARK: - 集合树

public struct CollectionNode: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case folder
        case request
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    /// 仅 kind == .request 时有值，指向 Project.requests 中的请求。
    public var requestID: UUID?
    public var children: [CollectionNode]
    /// 历史字段：展开状态早期存在项目文件里，每次展开 / 折叠都会把整个项目重新落盘。
    /// 现在展开状态由 `AppStore.collapsedFolderIDs` 记在工作区里，这个字段只在
    /// 首次升级时用来迁移旧值，界面与树扁平化都不再读它。
    public var isExpanded: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        requestID: UUID? = nil,
        children: [CollectionNode] = [],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.requestID = requestID
        self.children = children
        self.isExpanded = isExpanded
    }

    public static func folder(name: String, children: [CollectionNode] = []) -> CollectionNode {
        CollectionNode(kind: .folder, name: name, children: children, isExpanded: true)
    }

    public static func request(id: UUID, name: String) -> CollectionNode {
        CollectionNode(kind: .request, name: name, requestID: id)
    }
}

public extension Array where Element == CollectionNode {
    /// 深度优先找到节点并原地修改。
    @discardableResult
    mutating func mutateNode(id: UUID, _ transform: (inout CollectionNode) -> Void) -> Bool {
        for index in indices {
            if self[index].id == id {
                transform(&self[index])
                return true
            }
            if self[index].children.mutateNode(id: id, transform) {
                return true
            }
        }
        return false
    }

    func node(id: UUID) -> CollectionNode? {
        for node in self {
            if node.id == id { return node }
            if let found = node.children.node(id: id) { return found }
        }
        return nil
    }

    @discardableResult
    mutating func removeNode(id: UUID) -> Bool {
        if let index = firstIndex(where: { $0.id == id }) {
            remove(at: index)
            return true
        }
        for index in indices where self[index].children.removeNode(id: id) {
            return true
        }
        return false
    }

    /// 自身（若为请求）与所有后代请求的 id。
    func containedRequestIDs() -> [UUID] {
        var ids: [UUID] = []
        for node in self {
            if node.kind == .request, let requestID = node.requestID {
                ids.append(requestID)
            }
            ids.append(contentsOf: node.children.containedRequestIDs())
        }
        return ids
    }

    /// 把请求插入指定文件夹（folderID 为 nil 时插入根）。
    mutating func insert(requestNode: CollectionNode, intoFolder folderID: UUID?) {
        guard let folderID else {
            append(requestNode)
            return
        }
        if !mutateNode(id: folderID, { $0.children.append(requestNode) }) {
            append(requestNode)
        }
    }

    /// 目标请求所在路径上的所有文件夹 id（从根到直接父级），用于从标签页反查定位时展开它们。
    func ancestorFolderIDs(of requestID: UUID) -> [UUID] {
        for node in self where node.kind == .folder {
            if node.children.contains(where: { $0.requestID == requestID }) {
                return [node.id]
            }
            let deeper = node.children.ancestorFolderIDs(of: requestID)
            if !deeper.isEmpty { return [node.id] + deeper }
        }
        return []
    }

    /// 树里所有文件夹的 id（全部展开 / 折叠时用）。
    func allFolderIDs() -> [UUID] {
        var ids: [UUID] = []
        for node in self where node.kind == .folder {
            ids.append(node.id)
            ids.append(contentsOf: node.children.allFolderIDs())
        }
        return ids
    }

    /// 请求在树中的节点 id。
    func nodeID(forRequest requestID: UUID) -> UUID? {
        for node in self {
            if node.kind == .request, node.requestID == requestID { return node.id }
            if let found = node.children.nodeID(forRequest: requestID) { return found }
        }
        return nil
    }
}

// MARK: - 扁平化可见行（供侧边栏按需渲染）

/// 侧边栏不递归渲染整棵树，而是先扁平化成「可见行」。
/// 单项目上千接口时，折叠状态下只有几十行需要渲染。
public struct TreeRow: Identifiable, Hashable, Sendable {
    public var node: CollectionNode
    public var level: Int
    public var isExpanded: Bool
    public var hasChildren: Bool
    public var matchedSelf: Bool
    /// 请求行的方法（用于侧边栏方法标记）。
    public var method: HTTPMethod?

    public var id: UUID { node.id }
    public var isFolder: Bool { node.kind == .folder }
}

public enum CollectionTree {
    /// - Parameters:
    ///   - collapsed: 处于折叠状态的文件夹 id；不在集合里的文件夹默认展开。
    ///   - methodLookup: 按请求 id 查方法，由调用方一次性构建索引，避免逐行 O(n) 查找。
    public static func rows(
        in nodes: [CollectionNode],
        filter: String = "",
        collapsed: Set<UUID> = [],
        methodLookup: (UUID) -> HTTPMethod? = { _ in nil }
    ) -> [TreeRow] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return build(nodes, level: 0, query: query, collapsed: collapsed, methodLookup: methodLookup)
    }

    private static func build(
        _ nodes: [CollectionNode],
        level: Int,
        query: String,
        collapsed: Set<UUID>,
        methodLookup: (UUID) -> HTTPMethod?
    ) -> [TreeRow] {
        var rows: [TreeRow] = []
        for node in nodes {
            let matched = query.isEmpty || node.name.lowercased().contains(query)
            var childRows: [TreeRow] = []
            if node.kind == .folder {
                childRows = build(
                    node.children, level: level + 1, query: query, collapsed: collapsed, methodLookup: methodLookup
                )
            }

            // 过滤时：自身命中或任一后代命中才显示该行。
            let visible = query.isEmpty || matched || !childRows.isEmpty
            guard visible else { continue }

            let isExpanded = !collapsed.contains(node.id)
            rows.append(
                TreeRow(
                    node: node,
                    level: level,
                    isExpanded: isExpanded,
                    hasChildren: !node.children.isEmpty,
                    matchedSelf: matched,
                    method: node.requestID.flatMap(methodLookup)
                )
            )

            // 搜索时自动展开命中路径，否则跟随用户手动展开状态。
            let shouldExpand = isExpanded || (!query.isEmpty && !childRows.isEmpty)
            if node.kind == .folder, shouldExpand {
                rows.append(contentsOf: childRows)
            }
        }
        return rows
    }
}

// MARK: - 项目

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var note: String
    public var environments: [APIEnvironment]
    public var activeEnvironmentID: UUID?
    /// 项目全局变量，所有环境共享。
    public var globals: [KeyValueItem]
    /// 项目全局请求头，项目下所有请求自动携带（请求内同名项覆盖）。
    public var globalHeaders: [KeyValueItem]
    public var collection: [CollectionNode]
    public var requests: [APIRequest]
    /// 收藏的接口 id。数组顺序就是「收藏」区里的置顶顺序：
    /// 新收藏追加到末尾，已有项位置不变——避免每次收藏都重排给人的位置记忆。
    public var favoriteRequestIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        environments: [APIEnvironment] = [],
        activeEnvironmentID: UUID? = nil,
        globals: [KeyValueItem] = [],
        globalHeaders: [KeyValueItem] = [],
        collection: [CollectionNode] = [],
        requests: [APIRequest] = [],
        favoriteRequestIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.environments = environments.isEmpty ? [APIEnvironment.default()] : environments
        self.activeEnvironmentID = activeEnvironmentID ?? self.environments.first?.id
        self.globals = globals
        self.globalHeaders = globalHeaders
        self.collection = collection
        self.requests = requests
        self.favoriteRequestIDs = favoriteRequestIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // `favoriteRequestIDs` 是后加的字段：磁盘上的老项目文件没有它，
    // 缺字段必须回落默认值而不是让整个项目解码失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        let decodedEnvironments = try container.decodeIfPresent([APIEnvironment].self, forKey: .environments) ?? []
        environments = decodedEnvironments.isEmpty ? [APIEnvironment.default()] : decodedEnvironments
        activeEnvironmentID = try container.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
            ?? environments.first?.id
        globals = try container.decodeIfPresent([KeyValueItem].self, forKey: .globals) ?? []
        globalHeaders = try container.decodeIfPresent([KeyValueItem].self, forKey: .globalHeaders) ?? []
        collection = try container.decodeIfPresent([CollectionNode].self, forKey: .collection) ?? []
        requests = try container.decodeIfPresent([APIRequest].self, forKey: .requests) ?? []
        favoriteRequestIDs = try container.decodeIfPresent([UUID].self, forKey: .favoriteRequestIDs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    // MARK: 环境

    public var activeEnvironment: APIEnvironment? {
        guard let activeEnvironmentID else { return environments.first }
        return environments.first { $0.id == activeEnvironmentID } ?? environments.first
    }

    public func environment(id: UUID?) -> APIEnvironment? {
        guard let id else { return nil }
        return environments.first { $0.id == id }
    }

    // MARK: 请求

    public func request(id: UUID) -> APIRequest? {
        requests.first { $0.id == id }
    }

    public func requestIndex(id: UUID) -> Int? {
        requests.firstIndex { $0.id == id }
    }

    /// 请求所在的文件夹 id（根目录返回 nil）。
    public func folderID(containingRequest requestID: UUID) -> UUID? {
        func searchFolder(_ nodes: [CollectionNode]) -> UUID? {
            for node in nodes where node.kind == .folder {
                if node.children.contains(where: { $0.requestID == requestID }) {
                    return node.id
                }
                if let found = searchFolder(node.children) { return found }
            }
            return nil
        }
        return searchFolder(collection)
    }

    /// 插入新请求并同步写入集合树。
    public mutating func insert(_ request: APIRequest, intoFolder folderID: UUID?) {
        requests.append(request)
        let node = CollectionNode.request(id: request.id, name: request.name)
        collection.insert(requestNode: node, intoFolder: folderID)
        updatedAt = Date()
    }

    /// 删除节点（文件夹会连同内部请求一起删除），返回被删除的请求 id。
    @discardableResult
    public mutating func removeNode(id: UUID) -> [UUID] {
        guard let node = collection.node(id: id) else { return [] }
        var doomed: [UUID] = []
        if node.kind == .request, let requestID = node.requestID {
            doomed.append(requestID)
        }
        doomed.append(contentsOf: node.children.containedRequestIDs())
        collection.removeNode(id: id)
        let doomedSet = Set(doomed)
        requests.removeAll { doomedSet.contains($0.id) }
        favoriteRequestIDs.removeAll { doomedSet.contains($0) }
        updatedAt = Date()
        return doomed
    }

    // MARK: 收藏

    public func isFavorite(_ requestID: UUID) -> Bool {
        favoriteRequestIDs.contains(requestID)
    }

    /// 收藏 / 取消收藏。收藏追加到列表末尾（位置稳定），取消按 id 移除。
    /// 返回切换后的状态。
    @discardableResult
    public mutating func toggleFavorite(_ requestID: UUID) -> Bool {
        guard requestIndex(id: requestID) != nil else { return false }
        if let index = favoriteRequestIDs.firstIndex(of: requestID) {
            favoriteRequestIDs.remove(at: index)
        } else {
            favoriteRequestIDs.append(requestID)
        }
        updatedAt = Date()
        return favoriteRequestIDs.contains(requestID)
    }

    /// 按置顶顺序取收藏的接口；已被删除的失效 id 直接跳过。
    public var favoriteRequests: [APIRequest] {
        favoriteRequestIDs.compactMap { request(id: $0) }
    }

    /// 重命名节点；若为请求，同时更新请求名。
    public mutating func renameNode(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var requestID: UUID?
        collection.mutateNode(id: id) { node in
            node.name = trimmed
            requestID = node.requestID
        }
        if let requestID, let index = requestIndex(id: requestID) {
            requests[index].name = trimmed
            requests[index].updatedAt = Date()
        }
        updatedAt = Date()
    }

    /// 按名称排序集合树（文件夹在前），用于导入后整理。
    public mutating func sortCollection() {
        func sorted(_ nodes: [CollectionNode]) -> [CollectionNode] {
            nodes
                .map { node -> CollectionNode in
                    var copy = node
                    copy.children = sorted(node.children)
                    return copy
                }
                .sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind == .folder }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
        }
        collection = sorted(collection)
    }
}
