import Foundation

/// `multipart/form-data` 编码器。
///
/// 单独成文件的理由：这是文件上传里唯一「出错就很难看出来」的部分——
/// 少一个 `\r\n`、boundary 前后不一致、文件名没转义，服务端只会回一个 400
/// 甚至直接解析出空文件。所以这里保持成一块纯逻辑，可以被自检逐字节断言。
public struct MultipartBody: Sendable {

    /// 单个文件上限。超过就明确报错，而不是让用户等半天再失败。
    public static let sizeLimit: Int64 = 200 * 1024 * 1024

    public let boundary: String
    private var storage = Data()
    private var isFinalized = false

    public init(boundary: String = MultipartBody.makeBoundary()) {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func appendText(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(MultipartBody.escape(name))\"\r\n\r\n")
        append("\(value)\r\n")
    }

    public mutating func appendFile(name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(MultipartBody.escape(name))\""
                + "; filename=\"\(MultipartBody.escape(fileName))\"\r\n"
        )
        append("Content-Type: \(mimeType)\r\n\r\n")
        storage.append(data)
        append("\r\n")
    }

    /// 写入结束分隔线。必须在取 `data` 之前调用一次。
    public mutating func finalize() {
        guard !isFinalized else { return }
        isFinalized = true
        append("--\(boundary)--\r\n")
    }

    public var data: Data { storage }

    // MARK: 内部

    private mutating func append(_ text: String) {
        storage.append(Data(text.utf8))
    }

    /// 名字里的引号 / 反斜杠 / 换行会破坏 `Content-Disposition` 的语法。
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    public static func makeBoundary() -> String {
        "APIClientBoundary-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// 按扩展名猜 MIME。猜不到就用 `application/octet-stream`——
    /// 服务端多数只认真实字节，但有几个 Java 框架会按 Content-Type 选解析器。
    public static func mimeType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "pdf": return "application/pdf"
        case "txt", "log", "md": return "text/plain"
        case "json": return "application/json"
        case "xml": return "application/xml"
        case "csv": return "text/csv"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        default: return "application/octet-stream"
        }
    }
}
