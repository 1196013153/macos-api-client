import Foundation

/// 接口搜索：名称 / URL / 拼接后的完整 URL / 备注 / 方法 五个目标，
/// 子串命中优先，子序列模糊命中兜底，按分档评分排序。
///
/// 纯函数、无副作用，评分细节全部可单测。
public enum RequestSearch {

    public struct Result: Identifiable, Sendable {
        public let request: APIRequest
        public let score: Int
        /// 拼上当前环境 baseURL 后的完整地址（供界面展示与解释命中原因）。
        public let fullURL: String

        public var id: UUID { request.id }

        public init(request: APIRequest, score: Int, fullURL: String) {
            self.request = request
            self.score = score
            self.fullURL = fullURL
        }
    }

    // MARK: 入口

    /// 搜索并按相关度降序返回。空关键词返回空数组（调用方据此决定展示树还是结果列表）。
    public static func search(_ requests: [APIRequest], query rawQuery: String, baseURL: String = "") -> [Result] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        return requests.compactMap { request in
            let fullURL = resolveFullURL(request.url, baseURL: baseURL)
            guard let score = score(request: request, fullURL: fullURL, query: query) else { return nil }
            return Result(request: request, score: score, fullURL: fullURL)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.request.name.localizedStandardCompare(rhs.request.name) == .orderedAscending
        }
    }

    // MARK: 评分

    /// 分档评分：子串 > 模糊，名称 > URL > 完整 URL > 备注 > 方法。
    /// 返回 nil 表示完全不匹配。
    public static func score(request: APIRequest, fullURL: String, query: String) -> Int? {
        var best = 0
        var matched = false

        // 每个目标只小写一次：上千接口 × 五个目标 × 子串 + 模糊两种匹配，重复小写是搜索耗时的大头。
        let name = request.name.lowercased()
        let url = request.url.lowercased()
        let note = request.note.lowercased()
        let hasDistinctFullURL = fullURL != request.url
        let full = hasDistinctFullURL ? fullURL.lowercased() : url

        if request.method.rawValue.lowercased().hasPrefix(query) {
            best = max(best, 40); matched = true
        }
        if let s = substringScore(query: query, inLowercased: name) {
            best = max(best, 1000 + s); matched = true
        }
        if let s = substringScore(query: query, inLowercased: url) {
            best = max(best, 600 + s); matched = true
        }
        if hasDistinctFullURL, let s = substringScore(query: query, inLowercased: full) {
            best = max(best, 500 + s); matched = true
        }
        if let s = substringScore(query: query, inLowercased: note) {
            best = max(best, 400 + s); matched = true
        }
        if let f = fuzzyScore(query: query, inLowercased: name) {
            best = max(best, 300 + f); matched = true
        }
        if let f = fuzzyScore(query: query, inLowercased: url) {
            best = max(best, 200 + f); matched = true
        }
        if hasDistinctFullURL, let f = fuzzyScore(query: query, inLowercased: full) {
            best = max(best, 150 + f); matched = true
        }
        if let f = fuzzyScore(query: query, inLowercased: note) {
            best = max(best, 120 + f); matched = true
        }

        return matched ? best : nil
    }

    /// 子串命中：位置越靠前分越高，前缀命中额外加分。
    public static func substringScore(query: String, in target: String) -> Int? {
        substringScore(query: query, inLowercased: target.lowercased())
    }

    private static func substringScore(query: String, inLowercased target: String) -> Int? {
        guard let range = target.range(of: query) else { return nil }
        let position = target.distance(from: target.startIndex, to: range.lowerBound)
        var score = 200 - min(position, 199)
        if position == 0 { score += 100 }
        return score
    }

    /// 子序列模糊匹配（VS Code 快速打开的简化版）：
    /// 关键词字符按顺序出现在目标里即算命中；连续命中、词首（跟在 `/ - _ . :` 后）命中加分；
    /// 命中位置越早、目标越短，分越高。返回 nil 表示字符序列凑不齐。
    public static func fuzzyScore(query: String, in target: String) -> Int? {
        fuzzyScore(query: query, inLowercased: target.lowercased())
    }

    private static func fuzzyScore(query: String, inLowercased target: String) -> Int? {
        // 按 Unicode 标量而不是 Character 逐个比：Character 要做字素切分，
        // 上千接口逐字扫描时它是模糊匹配的主要开销；接口名 / URL 里没有组合字符，结果一样。
        let queryChars = Array(query.unicodeScalars)
        let targetChars = Array(target.unicodeScalars)
        guard !queryChars.isEmpty, queryChars.count <= targetChars.count else { return nil }

        var queryIndex = 0
        var score = 0
        var lastMatchIndex = -2
        var firstMatchIndex = -1

        for (index, char) in targetChars.enumerated() {
            guard queryIndex < queryChars.count, char == queryChars[queryIndex] else { continue }
            if firstMatchIndex < 0 { firstMatchIndex = index }
            if index == lastMatchIndex + 1 { score += 8 }
            if index == 0 || wordBoundaryScalars.contains(targetChars[index - 1]) { score += 6 }
            score += 1
            lastMatchIndex = index
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }
        score -= min(firstMatchIndex, 100)
        score -= (targetChars.count - queryChars.count) / 8
        return max(score, 1)
    }

    private static let wordBoundaryScalars: Set<Unicode.Scalar> = ["/", "-", "_", ".", ":"]

    /// 与 `RequestBuilder` 的 joinURL 同规则：绝对地址原样，相对路径拼 baseURL。
    /// 只用于搜索匹配，不做变量替换（`{{baseUrl}}` 等保持字面量）。
    public static func resolveFullURL(_ url: String, baseURL: String) -> String {
        let path = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("://") else { return path }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return path }
        if path.hasPrefix("/") {
            return base.hasSuffix("/") ? String(base.dropLast()) + path : base + path
        }
        return base.hasSuffix("/") ? base + path : base + "/" + path
    }
}
