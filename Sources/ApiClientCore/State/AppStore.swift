import Foundation
import Observation

/// 应用中央状态：项目列表 + 按项目隔离的标签页 + 设置 + 落盘调度。
///
/// 设计要点：
/// - 项目以值类型 `Project` 存数组，所有修改走 `updateProject`，避免外部持有副本造成状态分叉。
/// - 标签页（`TabSession`）是引用类型：视图直接观察它的编辑缓冲与响应变化。
/// - 标签页按项目隔离：`sessions` 是全部标签的容器，`visibleSessions` 才是当前项目的那一套，
///   每个项目各自记住自己停在哪个标签上（`activeTabByProject`）。
/// - 落盘走 `PersistenceWriter` actor + 防抖，主线程不碰文件 IO。
@MainActor
@Observable
public final class AppStore {

    public struct Notice: Identifiable, Equatable {
        public enum Level: Equatable, Sendable { case info, error }
        public let id = UUID()
        public var text: String
        public var level: Level
    }

    // MARK: 状态

    public internal(set) var projects: [Project] = [] {
        didSet { sidebarVersion += 1 }
    }
    public internal(set) var sessions: [TabSession] = []
    /// 启动时读取失败的项目文件（不阻塞启动，界面提示）。
    public private(set) var loadFailures: [String] = []
    public var activeProjectID: UUID? {
        didSet { sidebarVersion += 1 }
    }
    public var settings: AppSettings
    /// 脚本 / 运行时变量（v1 预留，优先级最高）。
    public var runtimeVariables: [String: String] = [:]
    public var sidebarFilter: String = "" {
        didSet { sidebarVersion += 1 }
    }
    public var notice: Notice?

    /// 折叠中的文件夹。展开状态是界面态：不进项目文件，只随工作区落盘，
    /// 这样展开 / 折叠既不会把上 MB 的项目重写一遍，也不会让所有读 `projects` 的视图刷新。
    public internal(set) var collapsedFolderIDs: Set<UUID> = [] {
        didSet { sidebarVersion += 1 }
    }

    /// 「把当前接口滚进侧边栏视野」的信号，每次 `revealRequest` +1，侧边栏据此滚动。
    /// 不挂在活动标签变化上：树里点的行本来就在眼前，收藏区点击也不定位，
    /// 只有切标签、保存新接口这类接口不在视野里的操作才需要滚动。
    public internal(set) var sidebarRevealTicket = 0

    /// 每个项目各自的活动标签。切项目就是切这一整套（标签 + 活动标签），互不干扰。
    public internal(set) var activeTabByProject: [UUID: UUID] = [:]

    /// 侧边栏派生数据（树行 / 收藏 / 搜索结果）的输入版本号：
    /// 项目、当前项目、搜索词、折叠状态任一变化就 +1。视图读派生属性时会顺带观察到它，
    /// 派生属性本身则按版本号缓存，一次输入变化只算一遍，不再是 body 里读几次算几次。
    private var sidebarVersion = 0
    @ObservationIgnored private var sidebarCache = SidebarCache()

    private struct SidebarCache {
        var rowsVersion = -1
        var rows: [TreeRow] = []
        var favoritesVersion = -1
        var favorites: [APIRequest] = []
        var searchVersion = -1
        var searchResults: [RequestSearch.Result] = []
    }

    public let storage: PersistenceStore
    public var storageRootPath: String { storage.paths.root.path }

    let writer: PersistenceWriter
    private var engine: HTTPEngine
    private var dirtyProjectIDs: Set<UUID> = []
    /// 防抖定时器。
    private var saveDebounceTask: Task<Void, Never>?
    /// 串行落盘链：每个写入任务先 await 前一个，保证「先发起的先落盘」。
    /// 否则先入队的写入可能晚于后入队的执行，退出应用时就会丢数据。
    private var saveChain: Task<Void, Never>?

    // MARK: 生命周期

    public init(storage: PersistenceStore = PersistenceStore()) {
        self.storage = storage
        self.writer = PersistenceWriter(store: storage)
        self.settings = AppSettings()
        self.engine = HTTPEngine(settings: AppSettings())
        bootstrap()
    }

    private func bootstrap() {
        try? storage.bootstrap()
        let workspace = storage.loadWorkspace()
        settings = workspace.settings
        engine = HTTPEngine(settings: settings)

        let loaded = storage.loadProjects()
        projects = loaded.projects
        loadFailures = loaded.failures

        if projects.isEmpty {
            let sample = AppStore.makeStarterProject()
            projects = [sample]
            enqueueSave(projects: [sample])
        }

        // 清理指向已删除项目的活动项目
        if let saved = workspace.activeProjectID, projects.contains(where: { $0.id == saved }) {
            activeProjectID = saved
        } else {
            activeProjectID = projects.first?.id
        }

        restoreCollapsedFolders(from: workspace)
        restoreTabs(from: workspace)
    }

    /// v3 之前折叠状态记在项目文件的 `isExpanded` 里：首次升级时迁移一次，之后只认工作区。
    private func restoreCollapsedFolders(from workspace: WorkspaceState) {
        if workspace.version >= 3 {
            collapsedFolderIDs = Set(workspace.collapsedFolderIDs)
            return
        }
        func collectCollapsed(_ nodes: [CollectionNode], into ids: inout Set<UUID>) {
            for node in nodes where node.kind == .folder {
                if !node.isExpanded { ids.insert(node.id) }
                collectCollapsed(node.children, into: &ids)
            }
        }
        var migrated: Set<UUID> = []
        for project in projects {
            collectCollapsed(project.collection, into: &migrated)
        }
        collapsedFolderIDs = migrated
    }

    /// 首次启动给一个能直接点的项目，避免空白界面。
    private static func makeStarterProject() -> Project {
        var project = Project(
            name: "我的第一个项目",
            note: "首次启动自动创建。可在顶部切换 / 新建项目。",
            environments: [APIEnvironment(name: "本地开发", baseURL: "http://127.0.0.1:8080")]
        )
        var folder = CollectionNode.folder(name: "示例")
        let health = APIRequest(
            name: "健康检查",
            method: .get,
            url: "{{baseUrl}}/api/health",
            mock: MockConfig(isEnabled: true, delayMs: 120),
            note: "相对路径会自动拼上当前环境的 baseUrl。这个示例默认开着 Mock，"
                + "点发送就能看到响应——不用先起服务。"
        )
        folder.children = [CollectionNode.request(id: health.id, name: health.name)]
        project.collection = [folder]
        project.requests = [health]
        return project
    }

    private func restoreTabs(from workspace: WorkspaceState) {
        var restored: [TabSession] = []
        for ref in workspace.openTabs {
            guard let project = project(id: ref.projectID) else { continue }
            if let requestID = ref.requestID {
                // 接口被删掉的旧标签直接丢弃
                guard let request = project.request(id: requestID) else { continue }
                restored.append(TabSession(id: ref.id, projectID: project.id, requestID: requestID, buffer: request))
            } else {
                restored.append(
                    TabSession(id: ref.id, projectID: project.id, requestID: nil, buffer: APIRequest.newDraft())
                )
            }
        }
        sessions = restored

        // 每个项目恢复自己上次停留的标签；记录失效（标签被关掉）时回落到该项目第一个标签。
        var restoredActive: [UUID: UUID] = [:]
        for project in projects {
            let candidates = restored.filter { $0.projectID == project.id }
            guard !candidates.isEmpty else { continue }
            if let saved = workspace.activeTab(for: project.id), candidates.contains(where: { $0.id == saved }) {
                restoredActive[project.id] = saved
            } else {
                restoredActive[project.id] = candidates[0].id
            }
        }
        activeTabByProject = restoredActive
    }

    // MARK: 派生数据

    public func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public var activeProject: Project? { project(id: activeProjectID) }

    public func session(id: UUID?) -> TabSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// 当前项目打开的标签。标签条只认这一个列表，别的项目的标签不会串进来。
    public var visibleSessions: [TabSession] {
        guard let activeProjectID else { return [] }
        return sessions.filter { $0.projectID == activeProjectID }
    }

    /// 当前项目停在哪张标签上（每个项目各记一份）。
    public var activeTabID: UUID? {
        get {
            guard let activeProjectID, let tabID = activeTabByProject[activeProjectID] else { return nil }
            // 标签可能已经被关掉，取值时校验一次，避免界面拿到失效 id。
            return sessions.contains { $0.id == tabID } ? tabID : nil
        }
        set {
            guard let activeProjectID else { return }
            if let newValue {
                activeTabByProject[activeProjectID] = newValue
            } else {
                activeTabByProject.removeValue(forKey: activeProjectID)
            }
        }
    }

    public var activeSession: TabSession? { session(id: activeTabID) }

    /// 某个项目打开了几个标签（项目切换器上显示，切走以后也知道标签去哪了）。
    public func openTabCount(projectID: UUID) -> Int {
        sessions.reduce(0) { $0 + ($1.projectID == projectID ? 1 : 0) }
    }

    /// 有打开标签的项目，按项目列表顺序（顶层项目标签条的数据源）。
    /// 用项目顺序而不是打开顺序：来回切换时 tab 位置不会跳。
    public var projectsWithTabs: [Project] {
        projects.filter { openTabCount(projectID: $0.id) > 0 }
    }

    /// 该项目是否有未保存的标签（项目 tab 上的脏点）。
    public func hasDirtyTabs(projectID: UUID) -> Bool {
        sessions.contains { $0.projectID == projectID && $0.isDirty }
    }

    /// 所有项目的接口总数（底部状态栏 / CLI 概览用）。
    public var totalRequestCount: Int {
        projects.reduce(0) { $0 + $1.requests.count }
    }

    /// 当前项目的收藏接口（置顶顺序）。
    /// 只在无搜索词的树模式下展示——搜索时侧边栏整体切换为平铺结果列表，
    /// 收藏的接口就在结果里（带金星），不再单开一区。
    public var sidebarFavorites: [APIRequest] {
        let version = sidebarVersion
        if sidebarCache.favoritesVersion != version {
            sidebarCache.favorites = activeProject?.favoriteRequests ?? []
            sidebarCache.favoritesVersion = version
        }
        return sidebarCache.favorites
    }

    /// 搜索结果：平铺、按相关度排序。空关键词返回空，由界面决定展示树还是结果列表。
    public var sidebarSearchResults: [RequestSearch.Result] {
        let version = sidebarVersion
        if sidebarCache.searchVersion != version {
            if let project = activeProject {
                sidebarCache.searchResults = RequestSearch.search(
                    project.requests,
                    query: sidebarFilter,
                    baseURL: project.activeEnvironment?.baseURL ?? ""
                )
            } else {
                sidebarCache.searchResults = []
            }
            sidebarCache.searchVersion = version
        }
        return sidebarCache.searchResults
    }

    public func isFavorite(projectID: UUID, requestID: UUID) -> Bool {
        project(id: projectID)?.isFavorite(requestID) ?? false
    }

    /// 侧边栏当前可见行（已按展开状态与搜索词扁平化）。
    public var sidebarRows: [TreeRow] {
        let version = sidebarVersion
        if sidebarCache.rowsVersion != version {
            if let project = activeProject {
                // 一次性建索引：文件夹展开后可能有上千行，逐行线性查找会退化成 O(n²)。
                let methods = Dictionary(
                    project.requests.map { ($0.id, $0.method) }, uniquingKeysWith: { first, _ in first }
                )
                sidebarCache.rows = CollectionTree.rows(
                    in: project.collection, filter: sidebarFilter, collapsed: collapsedFolderIDs
                ) { methods[$0] }
            } else {
                sidebarCache.rows = []
            }
            sidebarCache.rowsVersion = version
        }
        return sidebarCache.rows
    }

    // MARK: 修改入口

    /// 所有项目修改的唯一入口：改完自动标脏 + 防抖落盘。
    public func updateProject(id: UUID, _ mutate: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        mutate(&projects[index])
        projects[index].updatedAt = Date()
        dirtyProjectIDs.insert(id)
        scheduleSave()
    }

    public func updateActiveProject(_ mutate: (inout Project) -> Void) {
        guard let activeProjectID else { return }
        updateProject(id: activeProjectID, mutate)
    }

    public func setNotice(_ text: String, level: Notice.Level = .info) {
        notice = Notice(text: text, level: level)
    }

    public func clearNotice() {
        notice = nil
    }

    // MARK: 项目 CRUD

    @discardableResult
    public func createProject(name: String, baseURL: String = "") -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            name: trimmed.isEmpty ? "新项目" : trimmed,
            environments: [APIEnvironment(name: "默认环境", baseURL: baseURL)]
        )
        projects.append(project)
        activeProjectID = project.id
        sidebarFilter = ""
        enqueueSave(projects: [project])
        flushSave()
        return project
    }

    public func renameProject(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateProject(id: id) { $0.name = trimmed }
    }

    @discardableResult
    public func duplicateProject(id: UUID) -> Project? {
        guard let source = project(id: id) else { return nil }

        var idMap: [UUID: UUID] = [:]
        let requests = source.requests.map { request -> APIRequest in
            var copy = request
            let newID = UUID()
            idMap[request.id] = newID
            copy.id = newID
            return copy
        }

        func remap(_ nodes: [CollectionNode]) -> [CollectionNode] {
            nodes.map { node in
                var copy = node
                copy.id = UUID()
                if let oldRequestID = node.requestID, let newRequestID = idMap[oldRequestID] {
                    copy.requestID = newRequestID
                }
                copy.children = remap(node.children)
                return copy
            }
        }

        var environmentMap: [UUID: UUID] = [:]
        let environments = source.environments.map { environment -> APIEnvironment in
            var copy = environment
            let newID = UUID()
            environmentMap[environment.id] = newID
            copy.id = newID
            copy.variables = environment.variables.map { var item = $0; item.id = UUID(); return item }
            return copy
        }

        let copy = Project(
            name: source.name + " 副本",
            note: source.note,
            environments: environments,
            activeEnvironmentID: source.activeEnvironmentID.flatMap { environmentMap[$0] } ?? environments.first?.id,
            globals: source.globals.map { var item = $0; item.id = UUID(); return item },
            globalHeaders: source.globalHeaders.map { var item = $0; item.id = UUID(); return item },
            collection: remap(source.collection),
            requests: requests
        )

        projects.append(copy)
        activeProjectID = copy.id
        sidebarFilter = ""
        enqueueSave(projects: [copy])
        flushSave()
        return copy
    }

    public func deleteProject(id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        sessions.removeAll { $0.projectID == id }
        if let activeTabID, !sessions.contains(where: { $0.id == activeTabID }) {
            self.activeTabID = sessions.first?.id
        }
        projects.removeAll { $0.id == id }
        dirtyProjectIDs.remove(id)

        if activeProjectID == id {
            activeProjectID = projects.first?.id
        }
        enqueueDeleteProject(id: id)
        flushSave()
    }

    public func setActiveProject(id: UUID) {
        guard projects.contains(where: { $0.id == id }) else { return }
        activeProjectID = id
        sidebarFilter = ""
        flushSave()
    }

    // MARK: 设置

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        engine = HTTPEngine(settings: settings)
        flushSave()
    }

    // MARK: 发送

    /// 预览实际会发出的地址（用于请求栏下方的实时提示）。
    /// 只解析地址部分：地址栏每敲一个字都会调到这里，不能把请求体（form-data 还会读文件）一起编排。
    public func previewURL(for session: TabSession) -> (url: String, unresolved: [String])? {
        guard let project = project(id: session.projectID) else { return nil }
        guard let resolved = try? RequestBuilder.resolveURL(
            request: session.buffer,
            project: project,
            environment: project.activeEnvironment,
            runtimeVariables: runtimeVariables
        ) else { return nil }
        return (resolved.urlString, resolved.unresolvedVariables)
    }

    /// 界面用：拿一次编排结果（失败返回 nil，不弹错）。
    public func resolvedRequest(for session: TabSession) -> ResolvedRequest? {
        guard let project = project(id: session.projectID) else { return nil }
        return try? RequestBuilder.resolve(
            request: session.buffer,
            project: project,
            environment: project.activeEnvironment,
            runtimeVariables: runtimeVariables
        )
    }

    /// 界面用：Mock 当前会生成什么（手写内容为空时用它做提示）。
    public func generatedMockBody(for session: TabSession) -> MockBody {
        guard let project = project(id: session.projectID) else {
            return MockBody(text: "", contentType: "application/json")
        }
        let context = RequestBuilder.context(
            project: project,
            environment: project.activeEnvironment,
            runtimeVariables: runtimeVariables
        )
        return MockEngine.autoBody(
            request: session.buffer,
            resolved: resolvedRequest(for: session),
            context: context,
            config: session.buffer.mock
        )
    }

    public func send(tabID: UUID) {
        guard let session = session(id: tabID) else { return }
        guard let project = project(id: session.projectID) else {
            session.failPreparation("项目已删除，无法发送")
            return
        }

        let context = RequestBuilder.context(
            project: project,
            environment: project.activeEnvironment,
            runtimeVariables: runtimeVariables
        )

        // Mock 命中：不发真实网络请求。
        // 这里刻意不让「地址解析失败」拦住发送——后端没就绪也能联调正是 Mock 的意义。
        if settings.shouldMock(session.buffer) {
            let request = session.buffer
            let config = request.mock
            let mode = settings.mockMode
            let resolved = try? RequestBuilder.resolve(
                request: request,
                project: project,
                environment: project.activeEnvironment,
                runtimeVariables: runtimeVariables
            )

            // detached：响应体的解码与 JSON 解析在构造 payload 时完成，不能落在主线程上。
            let task = Task.detached {
                let payload = await MockEngine.respond(
                    request: request,
                    resolved: resolved,
                    context: context,
                    config: config,
                    mode: mode
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { session.finish(with: payload) }
            }
            session.beginSending(task: task)
            return
        }

        let resolved: ResolvedRequest
        do {
            resolved = try RequestBuilder.resolve(
                request: session.buffer,
                project: project,
                environment: project.activeEnvironment,
                runtimeVariables: runtimeVariables
            )
        } catch {
            session.failPreparation(error.localizedDescription)
            // 文件缺了 / 地址错了，把用户直接带到出问题的分区，
            // 否则报错只出现在响应面板，人还在参数页发懵。
            if session.buffer.body.kind.isMultipart {
                session.activePane = .body
            }
            return
        }

        let urlRequest: URLRequest
        do {
            urlRequest = try RequestBuilder.build(resolved, settings: settings)
        } catch {
            session.failPreparation(error.localizedDescription)
            return
        }

        let engine = self.engine
        let task = Task.detached {
            let payload = await engine.send(urlRequest, resolved: resolved) { snapshot in
                Task { @MainActor in session.receiveStream(snapshot) }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { session.finish(with: payload) }
        }
        session.beginSending(task: task)
    }

    public func cancelSend(tabID: UUID) {
        session(id: tabID)?.cancel()
    }

    public func cancelAllSends() {
        sessions.forEach { $0.cancel() }
    }

    // MARK: 落盘

    public func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.flushSave()
        }
    }

    /// 立即把脏项目与工作区状态排入落盘队列（退出前 / 结构性变更后调用）。
    public func flushSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil

        let pending = takePendingWrites()
        enqueueSave(projects: pending.projects, workspace: pending.workspace)
    }

    /// 排入落盘队列并等待「此前所有写入 + 本次写入」全部完成。
    /// 用于退出应用前与自检等需要「落盘已确定」的场景。
    public func flushSaveAndWait() async {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil

        let pending = takePendingWrites()
        enqueueSave(projects: pending.projects, workspace: pending.workspace)
        await saveChain?.value
    }

    /// 把写入挂到串行链尾：先等前一个写入完成，再执行自己的写入。
    func enqueueSave(projects: [Project], workspace: WorkspaceState? = nil) {
        let previous = saveChain
        let writer = self.writer
        saveChain = Task {
            await previous?.value
            await writer.save(projects: projects, workspace: workspace)
        }
    }

    /// 删除项目文件同样要排队，避免「先删后写」被乱序成「先写后删」。
    func enqueueDeleteProject(id: UUID) {
        let previous = saveChain
        let writer = self.writer
        saveChain = Task {
            await previous?.value
            await writer.deleteProject(id: id)
        }
    }

    /// 等待落盘队列排空（退出前调用）。
    public func waitForPendingWrites() async {
        await saveChain?.value
    }

    private func takePendingWrites() -> (projects: [Project], workspace: WorkspaceState) {
        let dirty = dirtyProjectIDs.compactMap { id in projects.first { $0.id == id } }
        dirtyProjectIDs.removeAll()
        return (dirty, workspaceSnapshot())
    }

    private func workspaceSnapshot() -> WorkspaceState {
        WorkspaceState(
            activeProjectID: activeProjectID,
            openTabs: sessions.map { TabRef(id: $0.id, projectID: $0.projectID, requestID: $0.requestID) },
            activeTabs: Dictionary(
                uniqueKeysWithValues: activeTabByProject.map { ($0.key.uuidString, $0.value) }
            ),
            activeTabID: activeTabID,
            collapsedFolderIDs: Array(collapsedFolderIDs),
            settings: settings
        )
    }
}
