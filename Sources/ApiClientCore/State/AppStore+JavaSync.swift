import Foundation

// MARK: - Java 项目接口同步

public extension AppStore {

    /// 绑定 Java 项目根目录并同步其中的 Spring Controller 接口。
    /// 扫描放后台线程，应用状态修改仍回主线程执行。
    func syncJavaInterfaces(projectID: UUID, folderURL: URL) async {
        do {
            let interfaces = try await Task.detached(priority: .userInitiated) {
                try JavaProjectScanner.scan(at: folderURL)
            }.value

            let result = applyJavaInterfaces(
                projectID: projectID,
                folderPath: folderURL.path,
                interfaces: interfaces
            )
            // 参数刷新完再改标签，否则标签会拿着旧缓冲把新参数盖回去。
            reconcileSessions(projectID: projectID, replacements: result.mergedRequestIDs)
            refreshTabsFromProject(id: projectID)
            setNotice(result.notice)
        } catch {
            setNotice("Java 接口同步失败：\(error.localizedDescription)", level: .error)
        }
    }

    private struct SyncResult {
        var added = 0
        var updated = 0
        var removed = 0
        /// 同源重复接口：被合并掉的请求 id -> 保留下来的请求 id。
        var mergedRequestIDs: [UUID: UUID] = [:]

        var notice: String {
            var text = "已同步 \(updated + added) 个接口：新增 \(added)，更新 \(updated)"
            if !mergedRequestIDs.isEmpty { text += "，合并重复 \(mergedRequestIDs.count)" }
            if removed > 0 { text += "，移除 \(removed)" }
            return text
        }
    }

    /// 认亲用的来源标识：Controller 目录名 + Java 方法名。
    private struct SyncIdentity: Hashable {
        var controller: String
        var method: String
    }

    private func applyJavaInterfaces(
        projectID: UUID,
        folderPath: String,
        interfaces: [JavaInterface]
    ) -> SyncResult {
        guard let old = project(id: projectID) else { return SyncResult() }

        let now = Date()
        var result = SyncResult()

        // 同一个来源在项目里可能有两份：早先导入的手工接口，和上一次同步生成的接口。
        // 先按 sourceKey 建索引，重复的只留第一份，其余记下来待合并。
        var generatedByKey: [String: APIRequest] = [:]
        for request in old.requests {
            guard let key = request.sourceKey else { continue }
            if let kept = generatedByKey[key] {
                result.mergedRequestIDs[request.id] = kept.id
            } else {
                generatedByKey[key] = request
            }
        }

        // 导入的接口没有 sourceKey，只能靠「所在目录 + 备注里的 Java 方法名」认出同一来源。
        let folderNames = requestFolderNames(in: old.collection)
        var importedByKey: [SyncIdentity: [APIRequest]] = [:]
        for request in old.requests where request.sourceKey == nil {
            guard let controller = folderNames[request.id],
                  let method = javaMethodName(in: request.note) else { continue }
            importedByKey[SyncIdentity(controller: controller, method: method), default: []].append(request)
        }

        let sourceKeys = Set(interfaces.map(\.sourceKey))
        var claimedIDs: Set<UUID> = []
        var updatedByID: [UUID: APIRequest] = [:]
        var newRequests: [APIRequest] = []

        for source in interfaces {
            let identity = SyncIdentity(controller: source.folderName, method: source.name)
            if let imported = importedByKey[identity]?.first(where: { !claimedIDs.contains($0.id) }) {
                // 认领导入的接口：原地升级成同步接口，这样重扫更新的是用户正在看的那一份，
                // 而不是再生成一份同名接口。同一来源的其余手工副本一并合并到它身上。
                for other in importedByKey[identity] ?? [] where other.id != imported.id {
                    claimedIDs.insert(other.id)
                    result.mergedRequestIDs[other.id] = imported.id
                }
                if let generated = generatedByKey[source.sourceKey], !claimedIDs.contains(generated.id) {
                    claimedIDs.insert(generated.id)
                    result.mergedRequestIDs[generated.id] = imported.id
                }
                claimedIDs.insert(imported.id)
                updatedByID[imported.id] = refresh(imported, with: source, at: now)
                result.updated += 1
            } else if let generated = generatedByKey[source.sourceKey], !claimedIDs.contains(generated.id) {
                claimedIDs.insert(generated.id)
                updatedByID[generated.id] = refresh(generated, with: source, at: now)
                result.updated += 1
            } else {
                let request = APIRequest(
                    name: source.name,
                    method: source.method,
                    url: source.url,
                    params: source.params,
                    headers: source.headers,
                    body: source.body,
                    note: source.note,
                    createdAt: now,
                    updatedAt: now,
                    sourceKey: source.sourceKey
                )
                newRequests.append(request)
                result.added += 1
            }
        }

        // 源码里已经不存在的同步接口（含被合并掉的重复项）从这里清出去。
        let staleIDs = old.requests.compactMap { request -> UUID? in
            guard let key = request.sourceKey, !sourceKeys.contains(key) else { return nil }
            return request.id
        }
        result.removed = staleIDs.count
        let droppedIDs = Set(staleIDs).union(result.mergedRequestIDs.keys)

        var newProject = old
        newProject.requests = old.requests.compactMap { request in
            guard !droppedIDs.contains(request.id) else { return nil }
            return updatedByID[request.id] ?? request
        } + newRequests
        newProject.favoriteRequestIDs = remappedFavorites(
            old.favoriteRequestIDs,
            merged: result.mergedRequestIDs,
            dropped: droppedIDs
        )

        // 已在树里的接口原地更新，目录与顺序都不动；只有新接口需要建节点。
        newProject.collection = prune(old.collection, removingRequestIDs: droppedIDs)
        for request in newRequests {
            let node = CollectionNode.request(id: request.id, name: request.name)
            let folderName = sourceFolderName(for: request.sourceKey)
            let folderID = folderID(named: folderName, in: &newProject.collection)
            newProject.collection.insert(requestNode: node, intoFolder: folderID)
        }

        newProject.javaSyncFolderPath = folderPath
        newProject.javaSyncedAt = now
        newProject.updatedAt = now

        updateProject(id: projectID) { $0 = newProject }
        flushSave()
        return result
    }

    /// 用扫描结果刷新已有接口：代码里能确定的部分覆盖掉，名字、Mock 与其它手工内容保留。
    private func refresh(_ request: APIRequest, with source: JavaInterface, at date: Date) -> APIRequest {
        var updated = request
        updated.method = source.method
        updated.url = source.url
        updated.params = source.params
        updated.headers = source.headers
        updated.body = source.body
        updated.note = mergedNote(request.note, scanned: source.note)
        updated.sourceKey = source.sourceKey
        updated.updatedAt = date
        return updated
    }

    /// 扫描结果只接管「Java: / 文件:」两行来源信息，说明里原有的业务描述继续保留。
    private func mergedNote(_ existing: String, scanned: String) -> String {
        let description = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("Java:") && !trimmed.hasPrefix("文件:")
            }
            .joined(separator: "\n")
        return description.isEmpty ? scanned : description + "\n" + scanned
    }

    /// 被合并掉的接口可能还挂在收藏里，改指保留下来的那份；接口没了的收藏直接丢弃。
    private func remappedFavorites(
        _ favorites: [UUID],
        merged: [UUID: UUID],
        dropped: Set<UUID>
    ) -> [UUID] {
        var seen: Set<UUID> = []
        return favorites.compactMap { id in
            let kept = survivor(of: id, merged: merged)
            guard !dropped.contains(kept), seen.insert(kept).inserted else { return nil }
            return kept
        }
    }

    /// 合并关系可能串成链（重复项 A -> 自动生成 B -> 导入的原件 C），一路跟到最终保留的那份。
    private func survivor(of id: UUID, merged: [UUID: UUID]) -> UUID {
        var current = id
        var visited: Set<UUID> = [id]
        while let next = merged[current], visited.insert(next).inserted {
            current = next
        }
        return current
    }

    /// 同步会合并 / 移除接口，标签页要跟着改指或关闭，避免停在已经不存在的接口上。
    private func reconcileSessions(projectID: UUID, replacements: [UUID: UUID]) {
        guard let project = project(id: projectID) else { return }

        for session in sessions where session.projectID == projectID {
            guard let requestID = session.requestID, replacements[requestID] != nil else { continue }
            session.requestID = survivor(of: requestID, merged: replacements)
        }

        let stale = sessions.filter { session in
            guard session.projectID == projectID, let requestID = session.requestID else { return false }
            return project.request(id: requestID) == nil
        }
        guard !stale.isEmpty else { return }

        stale.forEach { $0.cancel() }
        let staleIDs = Set(stale.map(\.id))
        sessions.removeAll { staleIDs.contains($0.id) }
        if let activeTabID, !sessions.contains(where: { $0.id == activeTabID }) {
            self.activeTabID = sessions.first?.id
        }
        flushSave()
    }

    /// 请求 id -> 所在文件夹名（根目录为空串），用来把导入的接口和扫描结果对上号。
    private func requestFolderNames(in nodes: [CollectionNode]) -> [UUID: String] {
        var result: [UUID: String] = [:]
        func walk(_ nodes: [CollectionNode], folder: String) {
            for node in nodes {
                switch node.kind {
                case .folder:
                    walk(node.children, folder: node.name)
                case .request:
                    if let requestID = node.requestID { result[requestID] = folder }
                }
            }
        }
        walk(nodes, folder: "")
        return result
    }

    /// 导入的接口把 Java 方法名写在备注里（`Java: 类.方法` 或 `Java: 方法`）。
    private func javaMethodName(in note: String) -> String? {
        for rawLine in note.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let range = line.range(of: "Java:") else { continue }
            let name = line[range.upperBound...]
                .split(separator: ".")
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return name }
        }
        return nil
    }

    private func sourceFolderName(for sourceKey: String?) -> String {
        // sourceKey 是 `相对文件#类#方法`，中间段就是 Controller 类名。
        guard let sourceKey else { return "同步接口" }
        let parts = sourceKey.split(separator: "#")
        return parts.count > 1 ? String(parts[1]) : "同步接口"
    }

    private func folderID(named name: String, in collection: inout [CollectionNode]) -> UUID? {
        var existingID: UUID?
        findFolder(named: name, in: collection, id: &existingID)
        if let existingID { return existingID }

        let folder = CollectionNode.folder(name: name)
        collection.append(folder)
        return folder.id
    }

    private func findFolder(named name: String, in nodes: [CollectionNode], id: inout UUID?) {
        for node in nodes where node.kind == .folder {
            if node.name == name {
                id = node.id
                return
            }
            findFolder(named: name, in: node.children, id: &id)
            if id != nil { return }
        }
    }

    private func prune(
        _ nodes: [CollectionNode],
        removingRequestIDs removed: Set<UUID>
    ) -> [CollectionNode] {
        nodes.compactMap { node in
            if node.kind == .request, let requestID = node.requestID, removed.contains(requestID) {
                return nil
            }
            var copy = node
            copy.children = prune(node.children, removingRequestIDs: removed)
            if copy.kind == .folder, copy.children.isEmpty {
                return nil
            }
            return copy
        }
    }
}
