import Foundation

/// 自动生成的 Mock 响应体。
public struct MockBody: Hashable, Sendable {
    public var text: String
    public var contentType: String

    public init(text: String, contentType: String) {
        self.text = text
        self.contentType = contentType
    }
}

/// Mock 响应生成。
///
/// 生成规则刻意「跟着请求走」，这样前端拿到的东西结构和真实接口是同一套语义：
/// - **请求方法**：GET/DELETE 这类没有请求体的，把 query / path 参数回显成 `data`；
///   POST/PUT/PATCH 则回显请求体。
/// - **请求体方式**：JSON 把请求体原样镜像进 `data`（字段名一致，前端可以直接照着渲染）；
///   Form 把表单字段整理成 JSON；Raw 返回 text/plain 回显原文；
///   无请求体返回 `data: null`。
///
/// 任何一步都可以被手写的响应体覆盖，见 `MockConfig.bodies`。
public enum MockEngine {

    // MARK: 对外入口

    /// 生成一次 Mock 响应（含模拟延迟）。
    public static func respond(
        request: APIRequest,
        resolved: ResolvedRequest?,
        context: VariableContext,
        config: MockConfig,
        mode: MockMode
    ) async -> HTTPResponsePayload {
        if config.delaySeconds > 0 {
            try? await Task.sleep(for: .seconds(config.delaySeconds))
        }
        return payload(request: request, resolved: resolved, context: context, config: config, mode: mode)
    }

    public static func payload(
        request: APIRequest,
        resolved: ResolvedRequest?,
        context: VariableContext,
        config: MockConfig,
        mode: MockMode
    ) -> HTTPResponsePayload {
        let custom = config.customBody(for: request.body.kind)
        let resolvedCustom = VariableResolver.text(custom, context: context)

        let body: MockBody
        if !resolvedCustom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = MockBody(
                text: resolvedCustom,
                contentType: responseContentType(for: request.body.kind)
            )
        } else {
            body = autoBody(request: request, resolved: resolved, context: context, config: config)
        }

        // 204 / 304 语义上不能带响应体。
        let data = (config.statusCode == 204 || config.statusCode == 304) ? Data() : Data(body.text.utf8)

        var headers: [HeaderField] = []
        if !data.isEmpty {
            headers.append(HeaderField(name: "Content-Type", value: body.contentType))
        }
        headers.append(HeaderField(name: "X-Mock", value: "true"))
        headers.append(HeaderField(name: "X-Mock-Mode", value: mode.rawValue))
        for item in config.headers.activeItems {
            guard let key = item.activeKey else { continue }
            let value = VariableResolver.text(item.value, context: context)
            if let index = headers.firstIndex(where: { $0.name.lowercased() == key.lowercased() }) {
                headers[index].value = value
            } else {
                headers.append(HeaderField(name: key, value: value))
            }
        }

        return HTTPResponsePayload(
            requestURL: resolved?.urlString ?? request.url,
            method: request.method.rawValue,
            statusCode: config.statusCode,
            statusText: MockConfig.statusText(for: config.statusCode),
            headers: headers,
            body: data,
            elapsed: config.delaySeconds,
            unresolvedVariables: resolved?.unresolvedVariables ?? [],
            isMock: true
        )
    }

    /// 按请求自动生成的响应体（界面上的「按请求生成」用的就是它）。
    public static func autoBody(
        request: APIRequest,
        resolved: ResolvedRequest?,
        context: VariableContext,
        config: MockConfig
    ) -> MockBody {
        switch request.body.kind {
        case .none:
            // 无请求体：这类请求的参数全在 query / path 上，回显出来才好对字段。
            let mirror = requestParameters(request, context: context)
            return MockBody(
                text: envelope(request, resolved: resolved, data: .object(mirror), config: config),
                contentType: "application/json"
            )

        case .json:
            let source = resolvedBodyText(request, resolved: resolved)
            let parsed = JSONValueParser.parse(source)
            let data: JSONValue
            switch parsed {
            case .some(let value) where value.isContainer:
                data = value
            case .some(let value):
                // 请求体是 `123` / `"abc"` 这类裸值，包一层保持响应是对象。
                data = .object([JSONEntry(key: "value", value: value)])
            case .none:
                data = source.isEmpty
                    ? .object([])
                    : .object([JSONEntry(key: "raw", value: .string(source))])
            }
            return MockBody(
                text: envelope(request, resolved: resolved, data: data, config: config),
                contentType: "application/json"
            )

        case .raw:
            let source = resolvedBodyText(request, resolved: resolved)
            let text = """
            [mock] \(request.method.rawValue) \(path(request, resolved: resolved))
            body-kind: raw

            \(source)
            """
            return MockBody(text: text, contentType: "text/plain")

        case .formURLEncoded:
            let mirror = formMirror(request, resolved: resolved, context: context)
            return MockBody(
                text: envelope(request, resolved: resolved, data: .object(mirror), config: config),
                contentType: "application/json"
            )

        case .formData:
            // multipart 的原文是二进制，回显它没有意义；按字段镜像，
            // 文件字段标出文件名，方便前端确认「哪个字段带了文件」。
            let mirror = formDataMirror(request, context: context)
            return MockBody(
                text: envelope(request, resolved: resolved, data: .object(mirror), config: config),
                contentType: "application/json"
            )
        }
    }

    private static func formDataMirror(_ request: APIRequest, context: VariableContext) -> [JSONEntry] {
        request.body.fields.activeItems.compactMap { item in
            guard let key = item.activeKey else { return nil }
            if item.isFile {
                let label = item.fileName.map { "[file] \($0)" } ?? "[file] 未选择文件"
                return JSONEntry(key: key, value: .string(label))
            }
            return JSONEntry(key: key, value: .string(VariableResolver.text(item.value, context: context)))
        }
    }

    // MARK: 内部

    /// 成功状态码用 `code: 0`（国内接口的惯例），失败给具体状态码。
    private static func envelope(
        _ request: APIRequest,
        resolved: ResolvedRequest?,
        data: JSONValue,
        config: MockConfig
    ) -> String {
        let isSuccess = !config.isErrorStatus
        let object = JSONValue.object([
            JSONEntry(key: "code", value: .number(isSuccess ? "0" : "\(config.statusCode)")),
            JSONEntry(key: "message", value: .string(isSuccess ? "success" : MockConfig.statusText(for: config.statusCode))),
            JSONEntry(key: "data", value: data),
            JSONEntry(
                key: "mock",
                value: .object([
                    JSONEntry(key: "method", value: .string(request.method.rawValue)),
                    JSONEntry(key: "path", value: .string(path(request, resolved: resolved))),
                    JSONEntry(key: "bodyKind", value: .string(request.body.kind.rawValue)),
                    JSONEntry(key: "delayMs", value: .number("\(config.delayMs)")),
                ])
            ),
        ])
        return object.prettyPrinted()
    }

    private static func responseContentType(for kind: RequestBodyKind) -> String {
        switch kind {
        case .none, .json, .formURLEncoded, .formData: return "application/json;charset=UTF-8"
        case .raw: return "text/plain;charset=UTF-8"
        }
    }

    /// 变量替换后的请求体原文。优先用编排结果，保证 Mock 里看到的就是真正会发出去的内容。
    private static func resolvedBodyText(_ request: APIRequest, resolved: ResolvedRequest?) -> String {
        if let data = resolved?.body, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return request.body.text
    }

    private static func requestParameters(_ request: APIRequest, context: VariableContext) -> [JSONEntry] {
        request.params.activeItems.compactMap { item in
            guard let key = item.activeKey else { return nil }
            return JSONEntry(key: key, value: .string(VariableResolver.text(item.value, context: context)))
        }
    }

    private static func formMirror(
        _ request: APIRequest,
        resolved: ResolvedRequest?,
        context: VariableContext
    ) -> [JSONEntry] {
        // 有编排结果时按真正发出的表单串解析（变量已替换、值已编码）；
        // 否则退回界面上的字段，至少能拿到结构。
        if let source = resolved.flatMap({ $0.body }).flatMap({ String(data: $0, encoding: .utf8) }), !source.isEmpty {
            let entries = source.split(separator: "&").compactMap { pair -> JSONEntry? in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = parts.first else { return nil }
                let key = decodeFormComponent(String(rawKey))
                let value = parts.count > 1 ? decodeFormComponent(String(parts[1])) : ""
                return JSONEntry(key: key, value: .string(value))
            }
            if !entries.isEmpty { return entries }
        }
        return request.body.fields.activeItems.compactMap { item in
            guard let key = item.activeKey else { return nil }
            return JSONEntry(key: key, value: .string(VariableResolver.text(item.value, context: context)))
        }
    }

    private static func decodeFormComponent(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    /// 只保留路径，去掉协议与主机，让 Mock 元信息保持简短。
    private static func path(_ request: APIRequest, resolved: ResolvedRequest?) -> String {
        let raw = resolved?.urlString ?? request.url
        guard let url = URL(string: raw), url.host != nil else { return raw.isEmpty ? "/" : raw }
        let path = url.path
        return path.isEmpty ? "/" : path
    }
}
