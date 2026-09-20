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
            setNotice(
                "已同步 \(result.updated + result.added) 个接口：新增 \(result.added)，更新 \(result.updated)，移除 \(result.removed)"
            )
        } catch {
            setNotice("Java 接口同步失败：\(error.localizedDescription)", level: .error)
        }
    }

    private struct SyncResult {
        var added = 0
        var updated = 0
        var removed = 0
    }

    private func applyJavaInterfaces(
        projectID: UUID,
        folderPath: String,
        interfaces: [JavaInterface]
    ) -> SyncResult {
        guard let old = project(id: projectID) else { return SyncResult() }

        let sourceKeys = Set(interfaces.map(\.sourceKey))
        var existingByKey: [String: APIRequest] = [:]
        for request in old.requests where request.sourceKey != nil {
            existingByKey[request.sourceKey!] = request
        }

        var syncedRequests: [APIRequest] = []
        var result = SyncResult()

        for source in interfaces {
            if var request = existingByKey[source.sourceKey] {
                request.name = source.name
                request.method = source.method
                request.url = source.url
                request.params = source.params
                request.headers = source.headers
                request.body = source.body
                request.note = source.note
                request.updatedAt = Date()
                result.updated += 1
                syncedRequests.append(request)
            } else {
                var request = APIRequest(
                    name: source.name,
                    method: source.method,
                    url: source.url,
                    params: source.params,
                    headers: source.headers,
                    body: source.body,
                    note: source.note
                )
                request.createdAt = Date()
                request.updatedAt = Date()
                request.sourceKey = source.sourceKey
                result.added += 1
                syncedRequests.append(request)
            }
        }

        let removedIDs = old.requests
            .filter { $0.sourceKey != nil && !sourceKeys.contains($0.sourceKey!) }
            .map(\.id)
        result.removed = removedIDs.count
        let removedSet = Set(removedIDs)

        let manualRequests = old.requests.filter { $0.sourceKey == nil }
        let manualCollection = prune(
            old.collection,
            removingRequestIDs: removedSet.union(Set(syncedRequests.map(\.id)))
        )

        var newProject = old
        newProject.requests = manualRequests + syncedRequests
        newProject.collection = manualCollection

        // 同步接口按 Controller 分目录；手工接口的集合树保持原样。
        var manualCollectionMutable = manualCollection
        for request in syncedRequests {
            let node = CollectionNode.request(id: request.id, name: request.name)
            let folderName = sourceFolderName(for: request.sourceKey)
            let folderID = folderID(named: folderName, in: &manualCollectionMutable)
            manualCollectionMutable.insert(requestNode: node, intoFolder: folderID)
        }
        newProject.collection = manualCollectionMutable

        newProject.javaSyncFolderPath = folderPath
        newProject.javaSyncedAt = Date()
        newProject.updatedAt = Date()

        updateProject(id: projectID) { $0 = newProject }
        flushSave()
        return result
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
