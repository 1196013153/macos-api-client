import Foundation

// MARK: - 标签页操作
//
// 标签页按项目隔离：标签条只显示当前项目的标签，全部标签操作（关闭其他 / 关闭全部 /
// 相邻切换）也都限定在当前项目内，不会误伤别的项目正在编辑的东西。

public extension AppStore {

    /// 打开接口：已打开则聚焦，否则在当前项目里新建标签。
    /// - Parameter reveal: 是否在侧边栏展开所在目录并滚动定位。树行 / 收藏区点击传 false：
    ///   前者本来就在视野里，后者按收藏的用法不该把树翻开——大目录展开 + 滚动是整次点击最卡的一段。
    func openRequest(projectID: UUID, requestID: UUID, reveal: Bool = true) {
        if let existing = sessions.first(where: { $0.projectID == projectID && $0.requestID == requestID }) {
            activeProjectID = projectID
            activeTabID = existing.id
            if reveal { revealRequest(projectID: projectID, requestID: requestID) }
            flushSave()
            return
        }

        guard let project = project(id: projectID),
              let request = project.request(id: requestID) else { return }

        let session = TabSession(projectID: projectID, requestID: requestID, buffer: request)
        sessions.append(session)
        activeProjectID = projectID
        activeTabID = session.id
        if reveal { revealRequest(projectID: projectID, requestID: requestID) }
        flushSave()
    }

    @discardableResult
    func newDraftTab(projectID: UUID? = nil) -> TabSession? {
        guard let targetProjectID = projectID ?? activeProjectID,
              project(id: targetProjectID) != nil else { return nil }

        let session = TabSession(
            projectID: targetProjectID,
            requestID: nil,
            buffer: APIRequest.newDraft()
        )
        sessions.append(session)
        activeProjectID = targetProjectID
        activeTabID = session.id
        flushSave()
        return session
    }

    func closeTab(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let projectID = sessions[index].projectID
        // 关掉的是该项目活动标签时，接位到它原来位置上的下一个同项目标签。
        let ordinal = sessions[..<index].filter { $0.projectID == projectID }.count
        let wasActive = activeTabByProject[projectID] == id

        sessions[index].cancel()
        sessions.remove(at: index)

        if wasActive {
            let remaining = sessions.filter { $0.projectID == projectID }
            if remaining.isEmpty {
                activeTabByProject.removeValue(forKey: projectID)
            } else {
                activeTabByProject[projectID] = remaining[min(ordinal, remaining.count - 1)].id
            }
        }
        flushSave()
    }

    /// 关闭当前项目里除该标签以外的标签（别的项目的标签不动）。
    func closeOtherTabs(keeping id: UUID) {
        guard let kept = session(id: id) else { return }
        let doomed = sessions.filter { $0.projectID == kept.projectID && $0.id != id }
        let doomedIDs = Set(doomed.map(\.id))
        doomed.forEach { $0.cancel() }
        sessions.removeAll { doomedIDs.contains($0.id) }
        activeTabByProject[kept.projectID] = id
        flushSave()
    }

    /// 关闭某个项目的全部标签。
    func closeAllTabs(for projectID: UUID) {
        sessions.filter { $0.projectID == projectID }.forEach { $0.cancel() }
        sessions.removeAll { $0.projectID == projectID }
        activeTabByProject.removeValue(forKey: projectID)
        flushSave()
    }

    /// 关闭所有项目的全部标签。
    func closeAllTabs() {
        sessions.forEach { $0.cancel() }
        sessions.removeAll()
        activeTabByProject.removeAll()
        flushSave()
    }

    /// 激活标签（标签条里的点击）。标签所属项目会成为当前项目。
    func activateTab(id: UUID) {
        guard let session = session(id: id) else { return }
        activeProjectID = session.projectID
        activeTabID = id
        if let requestID = session.requestID {
            revealRequest(projectID: session.projectID, requestID: requestID)
        }
        flushSave()
    }

    /// 在当前项目的标签之间循环切换。
    func activateAdjacentTab(offset: Int) {
        let tabs = visibleSessions
        guard tabs.count > 1, let currentID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        let count = tabs.count
        let next = ((index + offset) % count + count) % count
        activateTab(id: tabs[next].id)
    }

    /// 在「有标签的项目」之间循环切换（顶层项目标签条）。
    /// 当前项目没有标签时，往前切到第一个、往后切到最后一个。
    func activateAdjacentProjectTab(offset: Int) {
        let tabs = projectsWithTabs
        guard tabs.count > 1 else { return }

        let next: Int
        if let index = tabs.firstIndex(where: { $0.id == activeProjectID }) {
            next = ((index + offset) % tabs.count + tabs.count) % tabs.count
        } else {
            next = offset >= 0 ? 0 : tabs.count - 1
        }
        setActiveProject(id: tabs[next].id)
    }

    /// 用户主动要求「在侧边栏中定位」：先退出搜索模式（搜索时树不显示），再展开 + 滚动。
    func locateInSidebar(projectID: UUID, requestID: UUID) {
        if activeProjectID != projectID { setActiveProject(id: projectID) }
        sidebarFilter = ""
        revealRequest(projectID: projectID, requestID: requestID)
    }

    /// 展开目标请求所在的所有文件夹，并通知侧边栏把它滚进视野。
    func revealRequest(projectID: UUID, requestID: UUID) {
        guard let project = project(id: projectID) else { return }
        let ancestors = project.collection.ancestorFolderIDs(of: requestID)
        if ancestors.contains(where: { collapsedFolderIDs.contains($0) }) {
            collapsedFolderIDs.subtract(ancestors)
        }
        sidebarRevealTicket += 1
    }
}

// MARK: - 编辑缓冲

public extension AppStore {

    /// 修改标签的编辑缓冲（不写回项目，Cmd+S 才落库）。
    /// 只有内容真的变了才标脏——否则点一下输入框再移开也会冒出「未保存」。
    func updateBuffer(tabID: UUID, _ mutate: (inout APIRequest) -> Void) {
        guard let session = session(id: tabID) else { return }
        let before = session.buffer
        mutate(&session.buffer)
        guard session.buffer != before else { return }
        session.markDirty()
    }

    func updateActiveBuffer(_ mutate: (inout APIRequest) -> Void) {
        guard let activeTabID else { return }
        updateBuffer(tabID: activeTabID, mutate)
    }

    /// 从项目定义里丢弃本节修改。
    func revertBuffer(tabID: UUID) {
        guard let session = session(id: tabID),
              let requestID = session.requestID,
              let request = project(id: session.projectID)?.request(id: requestID) else { return }
        session.buffer = request
        session.isDirty = false
    }

    /// 保存标签（草稿 → 新建接口；已保存 → 覆盖）。
    @discardableResult
    func saveTab(tabID: UUID, asNew: Bool = false) -> Bool {
        guard let session = session(id: tabID),
              let project = project(id: session.projectID) else { return false }

        var buffer = session.buffer
        if buffer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            buffer.name = AppStore.deriveName(from: buffer)
        }
        buffer.updatedAt = Date()

        let isExisting = !asNew && session.requestID != nil
            && project.request(id: session.requestID!) != nil

        if isExisting, let requestID = session.requestID {
            updateProject(id: project.id) { target in
                if let index = target.requestIndex(id: requestID) {
                    target.requests[index] = buffer
                }
                if let nodeID = target.collection.nodeID(forRequest: requestID) {
                    target.collection.mutateNode(id: nodeID) { $0.name = buffer.name }
                }
            }
            session.commit(requestID: requestID, buffer: buffer)
            setNotice("已保存「\(buffer.name)」")
        } else {
            var saved = buffer
            if asNew || session.requestID != nil {
                // 另存为：换新 id，避免覆盖原接口（Mock 配置一起带过去）
                saved = APIRequest(
                    name: buffer.name,
                    method: buffer.method,
                    url: buffer.url,
                    params: buffer.params,
                    headers: buffer.headers,
                    body: buffer.body,
                    mock: buffer.mock,
                    note: buffer.note
                )
            }
            let inserted = saved
            updateProject(id: project.id) { target in
                target.insert(inserted, intoFolder: nil)
            }
            session.commit(requestID: saved.id, buffer: saved)
            revealRequest(projectID: project.id, requestID: saved.id)
            setNotice("已保存「\(saved.name)」")
        }
        return true
    }

    /// 保存后由 URL 推断一个可读的名字。
    static func deriveName(from request: APIRequest) -> String {
        let raw = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "新建请求" }

        if let url = URL(string: raw), !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" {
            return url.lastPathComponent
        }
        let components = raw.split(separator: "/").map(String.init)
        return components.last.map { $0.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "") } ?? "新建请求"
    }
}

// MARK: - 集合树 / 环境 / 变量

public extension AppStore {

    @discardableResult
    func addFolder(projectID: UUID, parentID: UUID?, name: String = "新建文件夹") -> UUID? {
        guard project(id: projectID) != nil else { return nil }
        let folder = CollectionNode.folder(name: name)
        updateProject(id: projectID) { project in
            if let parentID {
                let inserted = project.collection.mutateNode(id: parentID) { node in
                    node.children.append(folder)
                }
                if !inserted { project.collection.append(folder) }
            } else {
                project.collection.append(folder)
            }
        }
        // 新建的东西要让人看见：父文件夹若折叠着就展开。
        if let parentID { collapsedFolderIDs.remove(parentID) }
        return folder.id
    }

    @discardableResult
    func addRequest(
        projectID: UUID,
        folderID: UUID?,
        name: String = "新建请求",
        method: HTTPMethod = .get,
        url: String = ""
    ) -> UUID? {
        guard project(id: projectID) != nil else { return nil }
        let request = APIRequest(name: name, method: method, url: url)
        updateProject(id: projectID) { project in
            project.insert(request, intoFolder: folderID)
        }
        if let folderID { collapsedFolderIDs.remove(folderID) }
        return request.id
    }

    func deleteNode(projectID: UUID, nodeID: UUID) {
        guard let project = project(id: projectID) else { return }
        let doomed = project.collection.node(id: nodeID).map { node -> Set<UUID> in
            var ids = Set(node.children.containedRequestIDs())
            if let requestID = node.requestID { ids.insert(requestID) }
            return ids
        } ?? []

        updateProject(id: projectID) { $0.removeNode(id: nodeID) }

        // 关掉指向已删除接口的标签，避免留下失效标签
        if !doomed.isEmpty {
            let stale = sessions.filter { session in
                guard let requestID = session.requestID else { return false }
                return doomed.contains(requestID)
            }
            stale.forEach { $0.cancel() }
            let staleIDs = Set(stale.map(\.id))
            sessions.removeAll { staleIDs.contains($0.id) }
            if let activeTabID, !sessions.contains(where: { $0.id == activeTabID }) {
                self.activeTabID = sessions.first?.id
            }
            flushSave()
        }
    }

    func renameNode(projectID: UUID, nodeID: UUID, name: String) {
        updateProject(id: projectID) { $0.renameNode(id: nodeID, to: name) }
        refreshTabsFromProject(id: projectID)
    }

    /// 收藏 / 取消收藏接口，返回切换后的状态（用于提示与星标反馈）。
    @discardableResult
    func toggleFavorite(projectID: UUID, requestID: UUID) -> Bool {
        var nowFavorite = false
        updateProject(id: projectID) { project in
            nowFavorite = project.toggleFavorite(requestID)
        }
        flushSave()
        setNotice(
            nowFavorite ? "已收藏，置顶到侧边栏「收藏」区" : "已取消收藏",
            level: .info
        )
        return nowFavorite
    }

    /// 展开 / 折叠只改工作区里的折叠集合，不碰项目文件。
    func toggleFolder(projectID: UUID, nodeID: UUID) {
        if collapsedFolderIDs.contains(nodeID) {
            collapsedFolderIDs.remove(nodeID)
        } else {
            collapsedFolderIDs.insert(nodeID)
        }
        scheduleSave()
    }

    func setAllFolders(projectID: UUID, expanded: Bool) {
        guard let project = project(id: projectID) else { return }
        let folders = project.collection.allFolderIDs()
        if expanded {
            collapsedFolderIDs.subtract(folders)
        } else {
            collapsedFolderIDs.formUnion(folders)
        }
        scheduleSave()
    }

    /// 接口定义在别处被改动后，把未编辑的标签同步过来。
    func refreshTabsFromProject(id projectID: UUID) {
        guard let project = project(id: projectID) else { return }
        for session in sessions where session.projectID == projectID {
            guard !session.isDirty, let requestID = session.requestID,
                  let request = project.request(id: requestID) else { continue }
            session.buffer = request
        }
    }

    // MARK: 环境

    @discardableResult
    func addEnvironment(projectID: UUID, name: String, baseURL: String) -> UUID? {
        guard project(id: projectID) != nil else { return nil }
        let environment = APIEnvironment(name: name, baseURL: baseURL)
        updateProject(id: projectID) { project in
            project.environments.append(environment)
            if project.activeEnvironmentID == nil {
                project.activeEnvironmentID = environment.id
            }
        }
        return environment.id
    }

    func deleteEnvironment(projectID: UUID, environmentID: UUID) {
        updateProject(id: projectID) { project in
            project.environments.removeAll { $0.id == environmentID }
            if project.activeEnvironmentID == environmentID {
                project.activeEnvironmentID = project.environments.first?.id
            }
        }
    }

    func setActiveEnvironment(projectID: UUID, environmentID: UUID) {
        updateProject(id: projectID) { $0.activeEnvironmentID = environmentID }
        setNotice("已切换到环境「\(project(id: projectID)?.activeEnvironment?.name ?? "")」")
    }

    func updateEnvironments(projectID: UUID, _ mutate: (inout [APIEnvironment]) -> Void) {
        updateProject(id: projectID) { mutate(&$0.environments) }
    }
}
