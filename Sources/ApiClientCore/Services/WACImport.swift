import Foundation

/// 导入 skill/参考项目已有的 `wac-workspace` / `wac-collection` 数据。
///
/// 参考项目（uTools 版 API Client）导出的工作区是扁平结构：
/// 项目下有 `requests` 数组，每个请求用 `folderId` 反查所属 Controller 目录。
/// 这里把它还原成本应用的「集合树 + 请求数组」。
public enum WACImportError: LocalizedError {
    case unrecognizedFormat
    case noProjects

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat:
            return "无法识别的文件格式（需要 wac-workspace / wac-collection / 本应用导出的项目 JSON）"
        case .noProjects:
            return "文件中没有可导入的项目"
        }
    }
}

public enum WACImport {

    public static func projects(from url: URL) throws -> [Project] {
        try projects(from: Data(contentsOf: url))
    }

    public static func projects(from data: Data) throws -> [Project] {
        let decoder = JSONDecoder()

        // 单项目 JSON（本应用导出的格式）
        if let project = try? decoder.decode(Project.self, from: data) {
            return [project]
        }

        guard let file = try? decoder.decode(WACFile.self, from: data) else {
            throw WACImportError.unrecognizedFormat
        }

        var rawProjects = file.projects ?? []
        if rawProjects.isEmpty, file.requests != nil {
            // wac-collection：顶层直接是单个项目
            rawProjects = [
                WACProject(
                    name: file.name,
                    description: file.description,
                    environments: file.environments,
                    globals: file.globals,
                    globalHeaders: file.globalHeaders,
                    requests: file.requests
                )
            ]
        }

        guard !rawProjects.isEmpty else { throw WACImportError.noProjects }
        return rawProjects.map(convert)
    }

    // MARK: - 转换

    private static func convert(_ source: WACProject) -> Project {
        let rawRequests = source.requests ?? []
        let folderNames = folderNames(for: rawRequests)

        // 单次遍历完成「请求转换 + 按 folderId 归组」，保持原文件顺序。
        var apiRequests: [APIRequest] = []
        var grouped: [String: [CollectionNode]] = [:]
        var folderOrder: [String] = []
        var rootNodes: [CollectionNode] = []

        for raw in rawRequests {
            let request = convert(raw)
            apiRequests.append(request)
            let node = CollectionNode.request(id: request.id, name: request.name)

            if let folderID = raw.folderId, !folderID.isEmpty {
                if grouped[folderID] == nil {
                    grouped[folderID] = []
                    folderOrder.append(folderID)
                }
                grouped[folderID]?.append(node)
            } else {
                rootNodes.append(node)
            }
        }

        for folderID in folderOrder {
            rootNodes.append(
                CollectionNode.folder(
                    name: folderNames[folderID] ?? folderID,
                    children: grouped[folderID] ?? []
                )
            )
        }

        var project = Project(
            name: source.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "导入项目",
            note: source.description ?? "",
            environments: convert(source.environments),
            globals: convert(source.globals),
            globalHeaders: convert(source.globalHeaders),
            collection: rootNodes,
            requests: apiRequests
        )
        project.sortCollection()
        return project
    }

    private static func convert(_ source: WACRequest) -> APIRequest {
        let method = HTTPMethod(rawValue: (source.method ?? "GET").uppercased()) ?? .get
        let url = source.url ?? ""

        let params = (source.params ?? []).map { item -> KeyValueItem in
            var location: ParamLocation = .query
            if let key = item.key {
                if item.type?.lowercased() == "path"
                    || url.contains(":\(key)")
                    || url.contains("{\(key)}") {
                    location = .path
                }
            }
            return KeyValueItem(
                isEnabled: item.enabled ?? true,
                key: item.key ?? "",
                value: item.value ?? "",
                note: item.remark ?? "",
                location: location
            )
        }

        var note = source.description ?? ""
        var body = RequestBody()
        if let sourceBody = source.body {
            switch (sourceBody.mode ?? "none").lowercased() {
            case "json":
                body = RequestBody(kind: .json, text: sourceBody.json ?? "")
            case "raw":
                body = RequestBody(kind: .raw, text: sourceBody.raw ?? "")
            case "urlencoded":
                body = RequestBody(kind: .formURLEncoded, fields: convert(sourceBody.urlencoded))
            case "form":
                // 真的 multipart：type=file 的字段标成文件字段，值留空等用户选本地文件。
                body = RequestBody(kind: .formData, fields: convertForm(sourceBody.form))
            default:
                body = RequestBody()
            }
        }

        return APIRequest(
            name: source.name?.nilIfEmpty ?? "未命名请求",
            method: method,
            url: url,
            params: params,
            headers: convert(source.headers),
            body: body,
            note: note
        )
    }

    private static func convert(_ source: [WACEnvironment]?) -> [APIEnvironment] {
        let environments = (source ?? []).map { item in
            APIEnvironment(
                name: item.name?.nilIfEmpty ?? "环境",
                baseURL: item.baseUrl ?? "",
                variables: convert(item.variables)
            )
        }
        return environments.isEmpty ? [APIEnvironment.default()] : environments
    }

    private static func convert(_ source: [WACKeyValue]?) -> [KeyValueItem] {
        (source ?? []).map { item in
            KeyValueItem(
                isEnabled: item.enabled ?? true,
                key: item.key ?? "",
                value: item.value ?? "",
                note: item.remark ?? ""
            )
        }
    }

    /// form-data 字段。`type` 为 file 的项保留为文件字段（源文件里没有本地路径）。
    private static func convertForm(_ source: [WACKeyValue]?) -> [KeyValueItem] {
        (source ?? []).map { item in
            let isFile = (item.type ?? "").lowercased() == "file"
            return KeyValueItem(
                isEnabled: item.enabled ?? true,
                key: item.key ?? "",
                value: isFile ? "" : (item.value ?? ""),
                note: item.remark ?? (isFile ? "文件字段：发送前需要选择本地文件" : ""),
                valueKind: isFile ? .file : .text
            )
        }
    }

    /// `f_2_AccountController` → `AccountController`
    private static func folderNames(for requests: [WACRequest]) -> [String: String] {
        var names: [String: String] = [:]
        for request in requests {
            guard let folderID = request.folderId, !folderID.isEmpty else { continue }
            let parts = folderID.split(separator: "_").map(String.init)
            names[folderID] = parts.count > 2 ? parts.dropFirst(2).joined(separator: "_") : folderID
        }
        return names
    }
}

// MARK: - 文件结构

private struct WACFile: Decodable {
    var format: String?
    var name: String?
    var description: String?
    var environments: [WACEnvironment]?
    var globals: [WACKeyValue]?
    var globalHeaders: [WACKeyValue]?
    var projects: [WACProject]?
    var requests: [WACRequest]?
}

private struct WACProject: Decodable {
    var name: String?
    var description: String?
    var environments: [WACEnvironment]?
    var globals: [WACKeyValue]?
    var globalHeaders: [WACKeyValue]?
    var requests: [WACRequest]?
}

private struct WACEnvironment: Decodable {
    var name: String?
    var baseUrl: String?
    var variables: [WACKeyValue]?
}

private struct WACKeyValue: Decodable {
    var key: String?
    var value: String?
    var enabled: Bool?
    var remark: String?
    var type: String?
}

private struct WACRequest: Decodable {
    var name: String?
    var folderId: String?
    var method: String?
    var url: String?
    var description: String?
    var params: [WACKeyValue]?
    var headers: [WACKeyValue]?
    var body: WACBody?
}

private struct WACBody: Decodable {
    var mode: String?
    var json: String?
    var raw: String?
    var form: [WACKeyValue]?
    var urlencoded: [WACKeyValue]?
}

private extension String {
    /// 去空白后为空则返回 nil。
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
