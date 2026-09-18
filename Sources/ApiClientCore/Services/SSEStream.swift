import Foundation

// MARK: - SSE 流式响应
//
// 响应头 `Content-Type: text/event-stream` 的响应不是「一次性收完再展示」，而是服务端
// 持续推送、直到它主动关闭（AI 对话 / 进度通知都是这种）。这里按 SSE 规范逐行解析：
//   - `data:` 可以多行，用换行拼起来；`event:` 是事件名；`id:` 是事件 id；`retry:` 忽略
//   - 空行 = 一个事件结束；`:` 开头的行是注释（常见的心跳），直接丢
//   - 半行、半个 UTF-8 字符都可能被 TCP 分包切开，所以在字节级缓冲，只解码完整的行

/// 一个已经收完的事件。
public struct SSEEvent: Identifiable, Hashable, Sendable {
    /// 序号，从 1 起，按到达顺序。
    public let id: Int
    /// `event:` 字段；服务端没给就是 nil（规范上等价于 `message`）。
    public var name: String?
    /// `id:` 字段。
    public var lastEventID: String?
    /// `data:` 字段（多行已用 `\n` 拼接）。
    public var data: String
    /// 距请求发起的秒数。
    public var receivedAt: TimeInterval

    public init(id: Int, name: String? = nil, lastEventID: String? = nil, data: String, receivedAt: TimeInterval) {
        self.id = id
        self.name = name
        self.lastEventID = lastEventID
        self.data = data
        self.receivedAt = receivedAt
    }
}

/// 一次流式响应的状态：事件列表 + 连接是否还开着。
public struct SSEStreamState: Hashable, Sendable {
    public var events: [SSEEvent]
    public var isOpen: Bool
    /// 结束原因（服务端关闭 / 手动停止 / 出错）；连接还开着时为 nil。
    public var endReason: String?

    public init(events: [SSEEvent] = [], isOpen: Bool = true, endReason: String? = nil) {
        self.events = events
        self.isOpen = isOpen
        self.endReason = endReason
    }
}

/// 增量解析器：喂多少字节都行，返回其中凑齐的事件。
public struct SSEParser: Sendable {
    private var buffer: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastEventID: String?
    private var nextSequence = 1

    public init() {}

    public mutating func feed(_ chunk: Data, at elapsed: TimeInterval) -> [SSEEvent] {
        buffer.append(contentsOf: chunk)
        var events: [SSEEvent] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineEnd = newline
            if lineEnd > 0, buffer[lineEnd - 1] == 0x0D { lineEnd -= 1 }   // \r\n
            let line = String(decoding: buffer[..<lineEnd], as: UTF8.self)
            buffer.removeSubrange(...newline)
            if let event = consume(line: line, at: elapsed) {
                events.append(event)
            }
        }
        return events
    }

    /// 连接结束时把没用空行收尾的最后一个事件也吐出来。
    public mutating func finish(at elapsed: TimeInterval) -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = consume(line: line, at: elapsed) { events.append(event) }
        }
        if let event = dispatch(at: elapsed) { events.append(event) }
        return events
    }

    // MARK: 内部

    private mutating func consume(line: String, at elapsed: TimeInterval) -> SSEEvent? {
        if line.isEmpty { return dispatch(at: elapsed) }
        if line.hasPrefix(":") { return nil }   // 注释 / 心跳

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }

        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        case "id": lastEventID = String(value)
        default: break   // retry 与未知字段忽略
        }
        return nil
    }

    private mutating func dispatch(at elapsed: TimeInterval) -> SSEEvent? {
        defer {
            dataLines.removeAll()
            eventName = nil
        }
        // 规范：没有 data 的空行不派发事件（只重置 event 名）。
        guard !dataLines.isEmpty else { return nil }
        let event = SSEEvent(
            id: nextSequence,
            name: eventName,
            lastEventID: lastEventID,
            data: dataLines.joined(separator: "\n"),
            receivedAt: elapsed
        )
        nextSequence += 1
        return event
    }
}
