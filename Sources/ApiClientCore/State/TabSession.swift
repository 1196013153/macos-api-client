import Foundation
import Observation

/// 单个标签页的运行时状态：一份编辑缓冲 + 一份自己的响应。
///
/// 标签只属于一个项目，标签条按项目隔离：切项目换的是一整套标签，
/// 切回来时连停在哪个分区、编辑器滚到哪一行都还是原样。
@MainActor
@Observable
public final class TabSession: Identifiable {
    public enum Phase: Equatable, Sendable {
        case idle
        case sending
        /// SSE 连接已建立、事件持续到达中（此时 `response` 已有值并不断更新）。
        case streaming
        case finished
    }

    public let id: UUID
    /// 标签所属项目。
    public var projectID: UUID
    /// nil 表示草稿标签（未保存为正式接口）。
    public var requestID: UUID?
    /// 编辑缓冲。所有编辑先落在这里，Cmd+S 才写回项目。
    public var buffer: APIRequest
    public var isDirty: Bool
    public var phase: Phase
    public var response: HTTPResponsePayload?
    public var lastSentAt: Date?
    /// 发送前的编排错误（地址为空、无法解析等）。
    public var prepareError: String?

    // MARK: 界面状态（每个标签各一份，互不干扰）

    /// 当前停在哪个分区（参数 / 请求头 / 请求体 / Mock / 说明）。
    public var activePane: RequestPane = .params
    /// 响应面板停在哪个分区（响应体 / 响应头 / 请求详情）。
    public var responsePane: ResponsePane = .body
    /// 响应体的展示方式（树形 / 原文）。
    public var responseBodyMode: ResponseBodyMode = .tree
    /// Mock 响应体编辑器停在哪一种请求体方式上；nil = 跟随请求体的方式。
    public var mockEditingKind: RequestBodyKind?
    /// 打开标签时「按内容自动定位一次」，之后用户自己切的分区不再被覆盖。
    public private(set) var didAutoLocate = false

    /// 编辑器在每种请求体方式下的光标与滚动位置。
    ///
    /// 刻意不参与观察：光标每动一下都会写这里，参与观察会让整棵树跟着刷新。
    @ObservationIgnored
    public var bodyAnchors: [String: BodyEditorAnchor] = [:]

    private var sendTask: Task<Void, Never>?

    public init(id: UUID = UUID(), projectID: UUID, requestID: UUID?, buffer: APIRequest) {
        self.id = id
        self.projectID = projectID
        self.requestID = requestID
        self.buffer = buffer
        self.isDirty = requestID == nil ? buffer.hasContent : false
        self.phase = .idle
        autoLocate()
    }

    public var isDraft: Bool { requestID == nil }
    public var isSending: Bool { phase == .sending || phase == .streaming }
    public var isStreaming: Bool { phase == .streaming }
    public var displayName: String {
        let name = buffer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let url = buffer.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? "未命名请求" : url
    }

    /// Mock 响应体编辑器实际编辑的方式：默认跟随请求体方式。
    public var effectiveMockKind: RequestBodyKind {
        let kind = mockEditingKind ?? buffer.body.kind
        return kind == .none ? .json : kind
    }

    // MARK: 自动定位

    /// 按接口内容决定打开时停在哪一栏：有请求体就停在请求体（JSON / Raw / Form / Form-data 就在那儿），
    /// 否则按参数 → Mock → 请求头的顺序找第一个有内容的。
    public func autoLocate() {
        guard !didAutoLocate else { return }
        didAutoLocate = true
        activePane = Self.preferredPane(for: buffer)
    }

    /// 「说明」**刻意不参与**自动定位：它是解释性文字（导入的接口会带上 Java 方法名），
    /// 不是「这次请求的内容在哪里」。之前把它当候选，导致 700 多个没有参数的接口
    /// 一打开就跳到说明页——用户要看的是方法、地址和参数。
    public static func preferredPane(for request: APIRequest) -> RequestPane {
        if hasBody(request) { return .body }
        if !request.params.activeItems.isEmpty { return .params }
        if request.mock.isEnabled { return .mock }
        if !request.headers.activeItems.isEmpty { return .headers }
        return .params
    }

    private static func hasBody(_ request: APIRequest) -> Bool {
        switch request.body.kind {
        case .none:
            return false
        case .json, .raw:
            return !request.body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .formURLEncoded, .formData:
            return !request.body.fields.activeItems.isEmpty
        }
    }

    // MARK: 生命周期

    public func markDirty() {
        isDirty = true
    }

    public func beginSending(task: Task<Void, Never>) {
        sendTask?.cancel()
        sendTask = task
        phase = .sending
        prepareError = nil
        response = nil
    }

    public func finish(with payload: HTTPResponsePayload) {
        response = payload
        phase = .finished
        lastSentAt = Date()
        sendTask = nil
    }

    /// 流式响应的中间快照（连接还开着）。已取消 / 已结束的标签忽略迟到的快照。
    public func receiveStream(_ payload: HTTPResponsePayload) {
        guard phase == .sending || phase == .streaming else { return }
        response = payload
        phase = .streaming
    }

    public func failPreparation(_ message: String) {
        prepareError = message
        phase = .finished
        response = nil
        sendTask = nil
    }

    public func cancel() {
        sendTask?.cancel()
        sendTask = nil
        // 流式响应停掉时保留已收到的事件，标成「已手动停止」；普通请求取消后回到空闲。
        if phase == .streaming, response?.stream?.isOpen == true {
            let elapsed = response?.elapsed ?? 0
            response?.closeStream(reason: "已手动停止", elapsed: elapsed)
            phase = .finished
            lastSentAt = Date()
        } else {
            phase = .idle
        }
    }

    /// 保存后把缓冲与项目定义对齐。
    public func commit(requestID: UUID, buffer: APIRequest) {
        self.requestID = requestID
        self.buffer = buffer
        self.isDirty = false
    }
}
