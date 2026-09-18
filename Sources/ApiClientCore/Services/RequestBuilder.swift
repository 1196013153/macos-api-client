import Foundation

public enum RequestBuildError: LocalizedError {
    case emptyURL
    case invalidURL(String)
    case unsupportedBodyEncoding
    /// form-data 里的文件字段没选文件（参数是该字段名）。
    case fileNotChosen(String)
    /// 选过的文件已经不在了（参数是字段名）。
    case fileMissing(String)
    case fileUnreadable(String)
    case fileTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "请求地址为空"
        case .invalidURL(let url):
            return "无法解析地址：\(url)"
        case .unsupportedBodyEncoding:
            return "请求体编码失败"
        case .fileNotChosen(let field):
            return "文件字段「\(field)」还没有选文件"
        case .fileMissing(let field):
            return "文件字段「\(field)」的文件已不存在，请重新选择"
        case .fileUnreadable(let path):
            return "读不到文件：\(path)"
        case .fileTooLarge(let field):
            let limit = ByteCountFormatter.string(fromByteCount: MultipartBody.sizeLimit, countStyle: .file)
            return "文件字段「\(field)」超过 \(limit) 上限"
        }
    }
}

/// form-data 里的一个字段（编码后仍保留，供 cURL 导出与界面展示使用）。
public struct FormPart: Hashable, Sendable {
    public var name: String
    /// 文本值，或文件在磁盘上的路径。
    public var value: String
    public var isFile: Bool
    public var fileName: String?
    public var mimeType: String?

    public init(
        name: String,
        value: String,
        isFile: Bool = false,
        fileName: String? = nil,
        mimeType: String? = nil
    ) {
        self.name = name
        self.value = value
        self.isFile = isFile
        self.fileName = fileName
        self.mimeType = mimeType
    }
}

/// 变量替换与 URL 组装完成后的「可发送请求」。
public struct ResolvedRequest: Sendable {
    public var method: String
    public var urlString: String
    public var headers: [(name: String, value: String)]
    public var body: Data?
    public var bodyDescription: String
    public var unresolvedVariables: [String]
    /// 仅 form-data 有值：字段清单（cURL 要按 -F 导出，界面要显示文件明细）。
    public var formParts: [FormPart]

    public init(
        method: String,
        urlString: String,
        headers: [(name: String, value: String)],
        body: Data?,
        bodyDescription: String,
        unresolvedVariables: [String],
        formParts: [FormPart] = []
    ) {
        self.method = method
        self.urlString = urlString
        self.headers = headers
        self.body = body
        self.bodyDescription = bodyDescription
        self.unresolvedVariables = unresolvedVariables
        self.formParts = formParts
    }

    public var url: URL? { URL(string: urlString) }
}

/// 请求编排：变量替换 → 路径参数 → 拼 baseURL → query → headers → body。
/// 纯函数，不产生副作用，便于单测与界面预览。
public enum RequestBuilder {

    public static func context(
        project: Project,
        environment: APIEnvironment?,
        runtimeVariables: [String: String]
    ) -> VariableContext {
        VariableContext(
            environment: environment?.resolvedVariables ?? [:],
            globals: project.globals.asDictionary,
            runtime: runtimeVariables,
            dynamic: VariableResolver.dynamicVariables(
                projectName: project.name,
                environmentName: environment?.name ?? "未选择环境"
            )
        )
    }

    /// 只编排地址（变量 → 路径参数 → baseURL → query），不碰请求头与请求体。
    /// 地址栏实时预览用它：请求体编排可能很重（form-data 要读文件），不该跟着每次按键跑。
    public struct ResolvedURL: Sendable {
        public var urlString: String
        public var unresolvedVariables: [String]
    }

    public static func resolveURL(
        request: APIRequest,
        project: Project,
        environment: APIEnvironment?,
        runtimeVariables: [String: String] = [:]
    ) throws -> ResolvedURL {
        let context = context(project: project, environment: environment, runtimeVariables: runtimeVariables)
        var unresolved: [String] = []
        let url = try resolveURL(request: request, environment: environment, context: context, unresolved: &unresolved)
        return ResolvedURL(urlString: url.absoluteString, unresolvedVariables: unresolved)
    }

    /// 解析为最终请求（不构造 URLRequest），界面可用来实时预览实际发出的地址。
    public static func resolve(
        request: APIRequest,
        project: Project,
        environment: APIEnvironment?,
        runtimeVariables: [String: String] = [:]
    ) throws -> ResolvedRequest {
        let context = context(
            project: project,
            environment: environment,
            runtimeVariables: runtimeVariables
        )

        var unresolved: [String] = []
        func track(_ resolution: VariableResolution) {
            for name in resolution.unresolved where !unresolved.contains(name) {
                unresolved.append(name)
            }
        }

        let finalURL = try resolveURL(request: request, environment: environment, context: context, unresolved: &unresolved)

        // 5. headers：项目全局头 → 请求头覆盖 → 自动 Content-Type
        var headers: [(name: String, value: String)] = []
        func setHeader(_ name: String, _ value: String) {
            if let index = headers.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                headers[index].value = value
            } else {
                headers.append((name: name, value: value))
            }
        }

        for item in project.globalHeaders.activeItems {
            guard let key = item.activeKey else { continue }
            let resolved = VariableResolver.resolve(item.value, context: context)
            track(resolved)
            setHeader(key, resolved.text)
        }

        for item in request.headers.activeItems {
            guard let key = item.activeKey else { continue }
            let resolved = VariableResolver.resolve(item.value, context: context)
            track(resolved)
            setHeader(key, resolved.text)
        }

        // 6. body
        let bodyResult = try resolveBody(request.body, context: context, track: track)
        if let contentType = bodyResult.contentType, !headers.contains(where: {
            $0.name.lowercased() == "content-type"
        }) {
            setHeader("Content-Type", contentType)
        }

        return ResolvedRequest(
            method: request.method.rawValue,
            urlString: finalURL.absoluteString,
            headers: headers,
            body: bodyResult.data,
            bodyDescription: bodyResult.description,
            unresolvedVariables: unresolved,
            formParts: bodyResult.formParts
        )
    }

    /// 地址部分的编排（步骤 1–4），`resolve` 与 `resolveURL` 共用。
    private static func resolveURL(
        request: APIRequest,
        environment: APIEnvironment?,
        context: VariableContext,
        unresolved: inout [String]
    ) throws -> URL {
        func track(_ resolution: VariableResolution) {
            for name in resolution.unresolved where !unresolved.contains(name) {
                unresolved.append(name)
            }
        }

        // 1. URL 变量替换
        let rawURL = request.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { throw RequestBuildError.emptyURL }

        let resolvedURL = VariableResolver.resolve(rawURL, context: context)
        track(resolvedURL)
        var urlString = resolvedURL.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. 路径参数 :id / {id}
        urlString = applyPathParams(
            urlString,
            params: request.pathParams,
            context: context,
            unresolved: &unresolved
        )

        // 3. 相对路径拼接环境 baseURL
        urlString = joinURL(base: environment?.baseURL ?? "", path: urlString)

        // 4. query 参数
        var queryItems: [URLQueryItem] = []
        for item in request.queryParams {
            guard let key = item.activeKey else { continue }
            let resolved = VariableResolver.resolve(item.value, context: context)
            track(resolved)
            queryItems.append(URLQueryItem(name: key, value: resolved.text))
        }

        let components = try makeComponents(from: urlString, queryItems: queryItems)

        guard let finalURL = components.url else {
            throw RequestBuildError.invalidURL(components.string ?? urlString)
        }
        return finalURL
    }

    public static func build(_ resolved: ResolvedRequest, settings: AppSettings = AppSettings()) throws -> URLRequest {
        guard let url = resolved.url else {
            throw RequestBuildError.invalidURL(resolved.urlString)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = resolved.method
        urlRequest.timeoutInterval = settings.requestTimeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for header in resolved.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        urlRequest.httpBody = resolved.body
        return urlRequest
    }

    /// 一步到位：解析 + 构造 URLRequest。
    public static func build(
        request: APIRequest,
        project: Project,
        environment: APIEnvironment?,
        runtimeVariables: [String: String] = [:],
        settings: AppSettings = AppSettings()
    ) throws -> (urlRequest: URLRequest, resolved: ResolvedRequest) {
        let resolved = try resolve(
            request: request,
            project: project,
            environment: environment,
            runtimeVariables: runtimeVariables
        )
        return (try build(resolved, settings: settings), resolved)
    }

    // MARK: - 内部

    private struct BodyResult {
        var data: Data?
        var contentType: String?
        var description: String
        var formParts: [FormPart] = []
    }

    private static func resolveBody(
        _ body: RequestBody,
        context: VariableContext,
        track: (VariableResolution) -> Void
    ) throws -> BodyResult {
        switch body.kind {
        case .none:
            return BodyResult(data: nil, contentType: nil, description: "无")

        case .json, .raw:
            let trimmed = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return BodyResult(data: nil, contentType: body.kind.defaultContentType, description: "空")
            }
            let resolved = VariableResolver.resolve(body.text, context: context)
            track(resolved)
            guard let data = resolved.text.data(using: .utf8) else {
                throw RequestBuildError.unsupportedBodyEncoding
            }
            return BodyResult(
                data: data,
                contentType: body.kind.defaultContentType,
                description: "\(body.kind == .json ? "JSON" : "Raw") · \(data.count) 字节"
            )

        case .formURLEncoded:
            var pairs: [String] = []
            for item in body.fields.activeItems {
                guard let key = item.activeKey else { continue }
                let resolved = VariableResolver.resolve(item.value, context: context)
                track(resolved)
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? key
                let encodedValue = resolved.text.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? ""
                pairs.append("\(encodedKey)=\(encodedValue)")
            }
            guard !pairs.isEmpty else {
                return BodyResult(data: nil, contentType: body.kind.defaultContentType, description: "空表单")
            }
            let joined = pairs.joined(separator: "&")
            return BodyResult(
                data: joined.data(using: .utf8),
                contentType: body.kind.defaultContentType,
                description: "Form · \(pairs.count) 个字段"
            )

        case .formData:
            return try resolveFormData(body, context: context, track: track)
        }
    }

    /// multipart/form-data：文本字段做变量替换，文件字段从磁盘读。
    /// 文件读不到就抛错——「静默漏掉一个文件」比发送失败更难查。
    private static func resolveFormData(
        _ body: RequestBody,
        context: VariableContext,
        track: (VariableResolution) -> Void
    ) throws -> BodyResult {
        let active = body.fields.activeItems
        guard !active.isEmpty else {
            return BodyResult(data: nil, contentType: nil, description: "空表单")
        }

        var multipart = MultipartBody()
        var parts: [FormPart] = []

        for item in active {
            guard let key = item.activeKey else { continue }

            if item.isFile {
                guard !item.filePath.isEmpty else { throw RequestBuildError.fileNotChosen(key) }
                guard item.fileExists else { throw RequestBuildError.fileMissing(key) }
                guard let size = item.fileSize, size <= MultipartBody.sizeLimit else {
                    throw RequestBuildError.fileTooLarge(key)
                }
                let url = URL(fileURLWithPath: item.filePath)
                guard let data = try? Data(contentsOf: url) else {
                    throw RequestBuildError.fileUnreadable(item.filePath)
                }
                let mime = MultipartBody.mimeType(forExtension: url.pathExtension)
                multipart.appendFile(
                    name: key,
                    fileName: url.lastPathComponent,
                    mimeType: mime,
                    data: data
                )
                parts.append(
                    FormPart(name: key, value: item.filePath, isFile: true, fileName: url.lastPathComponent, mimeType: mime)
                )
            } else {
                let resolved = VariableResolver.resolve(item.value, context: context)
                track(resolved)
                multipart.appendText(name: key, value: resolved.text)
                parts.append(FormPart(name: key, value: resolved.text))
            }
        }

        multipart.finalize()
        let fileCount = parts.filter(\.isFile).count
        return BodyResult(
            data: multipart.data,
            contentType: multipart.contentType,
            description: "Form-data · \(parts.count) 个字段" + (fileCount > 0 ? "（含 \(fileCount) 个文件）" : ""),
            formParts: parts
        )
    }

    private static func applyPathParams(
        _ url: String,
        params: [KeyValueItem],
        context: VariableContext,
        unresolved: inout [String]
    ) -> String {
        let active = params.activeItems
        guard !active.isEmpty else { return url }

        // 只在 query 之前的部分做替换，避免误伤查询串里的冒号。
        var path = url
        var query = ""
        if let index = url.firstIndex(of: "?") {
            path = String(url[url.startIndex..<index])
            query = String(url[index...])
        }

        for item in active {
            guard let key = item.activeKey else { continue }
            let resolved = VariableResolver.resolve(item.value, context: context)
            for name in resolved.unresolved where !unresolved.contains(name) {
                unresolved.append(name)
            }
            let encoded = resolved.text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? resolved.text
            path = path.replacingOccurrences(of: ":\(key)", with: encoded)
            path = path.replacingOccurrences(of: "{\(key)}", with: encoded)
        }

        return path + query
    }

    private static func joinURL(base: String, path: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = path.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            return path
        }
        guard !trimmedBase.isEmpty else { return path }

        var normalizedBase = trimmedBase
        while normalizedBase.hasSuffix("/") { normalizedBase.removeLast() }
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return normalizedBase + normalizedPath
    }

    private static func makeComponents(from urlString: String, queryItems: [URLQueryItem]) throws -> URLComponents {
        var components: URLComponents?
        if let parsed = URLComponents(string: urlString) {
            components = parsed
        } else {
            // 地址里含空格、中文等非法字符时做最小转义再试一次。
            var allowed = CharacterSet.urlQueryAllowed
            allowed.insert(charactersIn: "#[]")
            if let escaped = urlString.addingPercentEncoding(withAllowedCharacters: allowed) {
                components = URLComponents(string: escaped)
            }
        }

        guard var result = components else {
            throw RequestBuildError.invalidURL(urlString)
        }
        guard !queryItems.isEmpty else { return result }

        var items = result.queryItems ?? []
        items.append(contentsOf: queryItems)
        result.queryItems = items
        return result
    }
}

// MARK: - cURL 导出

public extension RequestBuilder {
    /// 生成可粘贴到终端的 cURL 命令。
    static func curlCommand(for resolved: ResolvedRequest) -> String {
        var parts = ["curl -X \(resolved.method)"]
        parts.append(quote(resolved.urlString))
        for header in resolved.headers {
            // multipart 的 Content-Type 带 boundary，curl 用 -F 时会自己生成，重复给会冲突。
            if !resolved.formParts.isEmpty, header.name.lowercased() == "content-type",
               header.value.lowercased().hasPrefix("multipart/form-data") {
                continue
            }
            parts.append("-H " + quote("\(header.name): \(header.value)"))
        }
        if !resolved.formParts.isEmpty {
            for part in resolved.formParts {
                if part.isFile {
                    var spec = "\(part.name)=@\(part.value)"
                    if let mime = part.mimeType { spec += ";type=\(mime)" }
                    parts.append("-F " + quote(spec))
                } else {
                    parts.append("-F " + quote("\(part.name)=\(part.value)"))
                }
            }
        } else if let body = resolved.body, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            parts.append("--data-raw " + quote(text))
        }
        if parts.count <= 3 {
            return parts.joined(separator: " ")
        }
        return parts[0] + " " + parts[1] + " \\\n  " + parts.dropFirst(2).joined(separator: " \\\n  ")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension CharacterSet {
    /// RFC 3986 中 query 值允许的字符。
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+")
        return set
    }()
}
