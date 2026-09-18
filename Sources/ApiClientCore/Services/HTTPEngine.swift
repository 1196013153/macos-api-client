import Foundation

public struct HeaderField: Hashable, Sendable, Identifiable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var id: String { "\(name)\u{1}\(value)" }
}

/// 一次请求的响应快照。失败时 `errorMessage` 有值，其余字段保留已知信息。
public struct HTTPResponsePayload: Sendable {
    public var requestURL: String
    public var method: String
    public var statusCode: Int
    public var statusText: String
    public var headers: [HeaderField]
    public var body: Data
    public var elapsed: TimeInterval
    public var finalURL: URL?
    public var errorMessage: String?
    public var unresolvedVariables: [String]
    /// 是否是 Mock 返回（没有发出真实网络请求）。界面上会打 MOCK 标记。
    public var isMock: Bool
    /// 响应体的文本形式（解码规则见 `decodeText`）。
    /// 构造时解码一次并存下来：响应面板每次刷新都读它，按需解码会让 MB 级响应体每帧重解一遍。
    public private(set) var text: String?
    /// 可折叠展示的 JSON 树（非 JSON 响应为 nil）。同样只在构造时解析一次。
    public private(set) var jsonValue: JSONValue?
    /// SSE 流式响应的事件与连接状态；普通响应为 nil。
    public var stream: SSEStreamState?

    public init(
        requestURL: String,
        method: String,
        statusCode: Int = 0,
        statusText: String = "",
        headers: [HeaderField] = [],
        body: Data = Data(),
        elapsed: TimeInterval = 0,
        finalURL: URL? = nil,
        errorMessage: String? = nil,
        unresolvedVariables: [String] = [],
        isMock: Bool = false
    ) {
        self.requestURL = requestURL
        self.method = method
        self.statusCode = statusCode
        self.statusText = statusText
        self.headers = headers
        self.body = body
        self.elapsed = elapsed
        self.finalURL = finalURL
        self.errorMessage = errorMessage
        self.unresolvedVariables = unresolvedVariables
        self.isMock = isMock

        let contentType = headers.first { $0.name.lowercased() == "content-type" }?.value
        let text = HTTPResponsePayload.decodeText(body, contentType: contentType)
        self.text = text
        self.jsonValue = HTTPResponsePayload.parseJSON(text)
    }

    public var isFailed: Bool { errorMessage != nil }
    public var isStream: Bool { stream != nil }

    /// 流式响应收到新数据：原始字节追加进 body，事件追加进 stream，耗时刷新为当前值。
    /// 原文按整个 body 重新解码（一次几十 KB 到几 MB，毫秒级），比拼接半个 UTF-8 字符稳妥。
    public mutating func appendStream(chunk: Data, events: [SSEEvent], elapsed: TimeInterval) {
        body.append(chunk)
        text = String(decoding: body, as: UTF8.self)
        stream?.events.append(contentsOf: events)
        self.elapsed = elapsed
    }

    public mutating func closeStream(reason: String, elapsed: TimeInterval) {
        stream?.isOpen = false
        stream?.endReason = reason
        self.elapsed = elapsed
    }

    public var isSuccess: Bool {
        guard errorMessage == nil else { return false }
        return (200..<400).contains(statusCode)
    }

    public var size: Int { body.count }

    public var contentType: String? {
        headers.first { $0.name.lowercased() == "content-type" }?.value
    }

    /// 按字符集解码响应体：UTF-8 → 响应头 charset → GB18030 → Latin-1 兜底。
    private static func decodeText(_ body: Data, contentType: String?) -> String? {
        guard !body.isEmpty else { return "" }
        if let utf8 = String(data: body, encoding: .utf8) { return utf8 }

        if let contentType, let charsetRange = contentType.range(of: "charset=", options: .caseInsensitive) {
            let raw = contentType[charsetRange.upperBound...]
                .prefix { !$0.isWhitespace && $0 != ";" }
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(raw as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let decoded = String(data: body, encoding: String.Encoding(rawValue: nsEncoding)) {
                    return decoded
                }
            }
        }

        // 国内接口偶尔返回 GBK 且不带 charset 声明。
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let decoded = String(data: body, encoding: gb18030), !decoded.contains("\u{FFFD}") {
            return decoded
        }

        return String(data: body, encoding: .isoLatin1)
    }

    private static func parseJSON(_ text: String?) -> JSONValue? {
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        return JSONValueParser.parse(trimmed)
    }

    /// 「秒 + 毫秒」的可读耗时。
    public var elapsedText: String {
        if elapsed < 1 { return String(format: "%.0f ms", elapsed * 1000) }
        return String(format: "%.2f s", elapsed)
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        return formatter
    }()

    public var sizeText: String {
        HTTPResponsePayload.sizeFormatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - 引擎

public final class HTTPEngine: NSObject, @unchecked Sendable {
    private let settings: AppSettings
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = settings.requestTimeout
        // 资源超时是整个响应的总时长上限。SSE 连接可能开着几十分钟，这里放宽到一天；
        // 普通请求仍受「两段数据之间的空闲超时」（timeoutIntervalForRequest）约束，不会无限等。
        configuration.timeoutIntervalForResource = 86_400
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        // 调试工具需要快速失败，不要静默等待网络恢复。
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": HTTPEngine.userAgent]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public static let userAgent = "APIClient/1.0 (macOS; native)"

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        super.init()
    }

    /// 发送并等待响应结束。
    ///
    /// 响应按分块收取（`ResponseCollector`），而不是 `URLSession.data(for:)` 一次性等全量：
    /// 服务端回 `text/event-stream` 时连接会一直开着，事件到一批就通过 `onStreamUpdate`
    /// 推给界面（已做节流），直到服务端关闭或用户取消才返回最终结果。普通响应行为不变。
    public func send(
        _ urlRequest: URLRequest,
        resolved: ResolvedRequest,
        onStreamUpdate: (@Sendable (HTTPResponsePayload) -> Void)? = nil
    ) async -> HTTPResponsePayload {
        var request = urlRequest
        if !settings.followRedirects {
            request.httpShouldHandleCookies = true
        }

        let collector = ResponseCollector(resolved: resolved, onStreamUpdate: onStreamUpdate)
        let task = session.dataTask(with: request)
        task.delegate = collector
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                collector.start(continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// 取消所有在途请求（关闭标签 / 退出时调用）。
    public func cancelAll() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return error.localizedDescription
        }
        switch urlError.code {
        case .timedOut: return "请求超时（可在设置里调大超时时间）"
        case .cannotFindHost: return "找不到主机，检查域名或网络"
        case .cannotConnectToHost: return "无法连接主机，检查服务是否启动 / 端口是否正确"
        case .networkConnectionLost: return "网络连接中断"
        case .notConnectedToInternet: return "当前无网络连接"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return "TLS 证书校验失败（自签证书可在设置里关闭「校验 TLS 证书」）"
        case .cancelled: return "请求已取消"
        case .unsupportedURL: return "地址格式不支持"
        default: return "\(urlError.localizedDescription)（URLError \(urlError.code.rawValue)）"
        }
    }
}

// MARK: - 分块收取

/// 单次请求的响应收集器（挂在 task 上的 delegate；TLS 与重定向仍由 session 级 delegate 处理）。
///
/// 两种模式在拿到响应头那一刻分流：`text/event-stream` 走流式（逐块解析、节流推送），
/// 其余照旧攒完整个 body 再一次性交付。
private final class ResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 事件推送节流：一批 token 级的事件几十毫秒内到齐，攒到一起刷一次界面。
    private static let flushInterval: TimeInterval = 0.08

    private let resolved: ResolvedRequest
    private let onStreamUpdate: (@Sendable (HTTPResponsePayload) -> Void)?
    private let start = Date()
    private let lock = NSLock()

    private var continuation: CheckedContinuation<HTTPResponsePayload, Never>?
    private var response: HTTPURLResponse?
    private var body = Data()
    // 流式模式的状态
    private var isStreaming = false
    private var parser = SSEParser()
    private var payload: HTTPResponsePayload?
    private var flushScheduled = false
    private var completed = false

    init(resolved: ResolvedRequest, onStreamUpdate: (@Sendable (HTTPResponsePayload) -> Void)?) {
        self.resolved = resolved
        self.onStreamUpdate = onStreamUpdate
    }

    func start(continuation: CheckedContinuation<HTTPResponsePayload, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    private var elapsed: TimeInterval { Date().timeIntervalSince(start) }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        self.response = http
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.hasPrefix("text/event-stream") {
            isStreaming = true
            var initial = makePayload(http: http, body: Data(), elapsed: elapsed)
            initial.stream = SSEStreamState()
            payload = initial
            onStreamUpdate?(initial)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard isStreaming else {
            body.append(data)
            return
        }
        let now = elapsed
        let events = parser.feed(data, at: now)
        payload?.appendStream(chunk: data, events: events, elapsed: now)
        scheduleFlushLocked()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        completed = true
        let now = elapsed
        let final: HTTPResponsePayload

        if isStreaming, var streamed = payload {
            let trailing = parser.finish(at: now)
            streamed.appendStream(chunk: Data(), events: trailing, elapsed: now)
            let reason: String
            if let error {
                reason = (error as? URLError)?.code == .cancelled ? "已手动停止" : HTTPEngine.describe(error)
            } else {
                reason = "服务端已结束"
            }
            streamed.closeStream(reason: reason, elapsed: now)
            final = streamed
        } else if let error {
            final = HTTPResponsePayload(
                requestURL: resolved.urlString,
                method: resolved.method,
                elapsed: now,
                errorMessage: HTTPEngine.describe(error),
                unresolvedVariables: resolved.unresolvedVariables
            )
        } else if let http = response {
            final = makePayload(http: http, body: body, elapsed: now)
        } else {
            final = HTTPResponsePayload(
                requestURL: resolved.urlString,
                method: resolved.method,
                body: body,
                elapsed: now,
                finalURL: task.response?.url,
                errorMessage: "响应不是 HTTP 响应",
                unresolvedVariables: resolved.unresolvedVariables
            )
        }

        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: final)
    }

    // MARK: 内部

    private func makePayload(http: HTTPURLResponse, body: Data, elapsed: TimeInterval) -> HTTPResponsePayload {
        HTTPResponsePayload(
            requestURL: resolved.urlString,
            method: resolved.method,
            statusCode: http.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            headers: http.allHeaderFields
                .map { HeaderField(name: "\($0.key)", value: "\($0.value)") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            body: body,
            elapsed: elapsed,
            finalURL: http.url,
            unresolvedVariables: resolved.unresolvedVariables
        )
    }

    /// 调用方须已持锁。
    private func scheduleFlushLocked() {
        guard !flushScheduled, !completed else { return }
        flushScheduled = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        // 结束后的最终结果走 continuation 交付，这里不再重复推。
        guard !completed, let snapshot = payload else {
            lock.unlock()
            return
        }
        lock.unlock()
        onStreamUpdate?(snapshot)
    }
}

extension HTTPEngine: URLSessionDelegate {
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // 关闭证书校验时，接受任意服务端证书（测试环境自签证书场景）。
        guard !settings.verifyTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// 关掉「跟随重定向」时，把 3xx 原样返回给用户查看。
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(settings.followRedirects ? request : nil)
    }
}
