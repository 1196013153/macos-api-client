import Foundation

/// Spring Controller 的轻量 Java 源码扫描结果。
public struct JavaInterface: Sendable, Hashable {
    public var name: String
    public var method: HTTPMethod
    public var url: String
    public var params: [KeyValueItem]
    public var headers: [KeyValueItem]
    public var body: RequestBody
    public var note: String
    public var sourceKey: String
    public var folderName: String
}

public enum JavaProjectScannerError: LocalizedError {
    case folderMissing
    case noInterfaces

    public var errorDescription: String? {
        switch self {
        case .folderMissing:
            return "绑定的文件夹不存在"
        case .noInterfaces:
            return "未在文件夹中找到 Spring Controller 接口"
        }
    }
}

/// 从 Java 源码读取 Spring MVC 注解接口。
///
/// 这里刻意保持轻量：不做完整 Java AST，只识别 `@RestController/@Controller`
/// 类和 `@RequestMapping/GetMapping/...` 方法注解。注解值以常见写法为准，
/// 目标是同步本机当前工程，而不是替代编译器。
public enum JavaProjectScanner {

    public static func scan(at root: URL) throws -> [JavaInterface] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw JavaProjectScannerError.folderMissing
        }

        let files = javaFiles(in: root).sorted { $0.path < $1.path }
        let interfaces = files.flatMap { parse(file: $0, root: root) }
        guard !interfaces.isEmpty else { throw JavaProjectScannerError.noInterfaces }
        return interfaces
    }

    private static func javaFiles(in root: URL) -> [URL] {
        let fm = FileManager.default
        let skipped = Set([".git", "build", "target", "node_modules", ".gradle", ".idea"])
        var result: [URL] = []
        var queue: [URL] = [root]

        while let directory = queue.popLast() {
            guard let items = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items where !skipped.contains(item.lastPathComponent) {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    queue.append(item)
                } else if item.pathExtension == "java" {
                    result.append(item)
                }
            }
        }
        return result
    }

    private static func parse(file: URL, root: URL) -> [JavaInterface] {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let source = stripComments(raw)
        let classMatches = matches(in: source, pattern: #"\bclass\s+(\w+)"#)
        guard let classMatch = classMatches.first else { return [] }

        let classStart = classMatch[1]!.lowerBound
        let declarationPrefix = source[source.startIndex..<classStart]
        guard declarationPrefix.contains("@RestController") || declarationPrefix.contains("@Controller") else {
            return []
        }

        let className = text(of: classMatch[1], in: source)
        var classBasePath = ""
        if let mapping = lastAnnotation(named: "RequestMapping", in: String(declarationPrefix)) {
            classBasePath = normalizePath(firstPath(mapping.value))
        }

        let body = String(source[source.index(after: classMatch[0]!.upperBound)...])
        let mappingMatches = annotationMatches(in: body).sorted { $0.range.lowerBound < $1.range.lowerBound }
        var interfaces: [JavaInterface] = []

        for (index, mapping) in mappingMatches.enumerated() {
            let upperBound = index + 1 < mappingMatches.count
                ? mappingMatches[index + 1].range.lowerBound
                : body.endIndex
            let searchRange = mapping.range.upperBound..<upperBound
            guard let signature = methodSignature(in: String(body[searchRange])) else {
                continue
            }

            let rootPath = root.resolvingSymlinksInPath().path
            let filePath = file.resolvingSymlinksInPath().path
            let relativePath = filePath.hasPrefix(rootPath + "/")
                ? String(filePath.dropFirst(rootPath.count + 1))
                : file.lastPathComponent
            let sourceKey = "\(relativePath)#\(className)#\(signature.name)"
            let interfaces1 = interface(
                className: className,
                classBasePath: classBasePath,
                annotation: mapping.annotation,
                signature: signature,
                sourceKey: sourceKey,
                relativePath: relativePath
            )
            interfaces.append(interfaces1)
        }
        return interfaces
    }

    private static func interface(
        className: String,
        classBasePath: String,
        annotation: Annotation,
        signature: MethodSignature,
        sourceKey: String,
        relativePath: String
    ) -> JavaInterface {
        var params: [KeyValueItem] = []
        var headers: [KeyValueItem] = []
        var requestBody = RequestBody()
        var hasRequestBody = false

        for parameter in signature.parameters {
            if parameter.has("PathVariable") {
                params.append(KeyValueItem(key: parameter.name, value: "", note: "路径参数", location: .path))
            } else if parameter.has("RequestParam") {
                params.append(KeyValueItem(key: parameter.name, value: "", note: "查询参数", location: .query))
            } else if parameter.has("RequestHeader") {
                headers.append(KeyValueItem(key: parameter.name, value: "", note: "请求头"))
            } else if parameter.has("RequestBody") {
                hasRequestBody = true
            }
        }

        if hasRequestBody {
            requestBody = RequestBody(kind: .json, text: "{}")
        }

        let url = joinPath(classBasePath, normalizePath(annotation.path))
        for variable in pathVariables(in: url) where !params.contains(where: { $0.key == variable && $0.location == .path }) {
            params.append(KeyValueItem(key: variable, value: "", note: "路径参数", location: .path))
        }

        return JavaInterface(
            name: signature.name,
            method: annotation.httpMethod,
            url: url,
            params: params,
            headers: headers,
            body: requestBody,
            note: "Java: \(className).\(signature.name)\n文件: \(relativePath)",
            sourceKey: sourceKey,
            folderName: className
        )
    }

    // MARK: - 注解 / 方法签名

    private struct Annotation {
        var name: String
        var value: String
        var httpMethod: HTTPMethod
        var path: String { firstPath(value) }
    }

    private struct MethodSignature {
        var name: String
        var parameters: [Parameter]
    }

    private struct Parameter {
        var annotations: String
        var declaration: String

        var name: String {
            if let explicit = firstString(in: annotations) { return explicit }
            let tokens = declaration
                .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            return tokens.last.map(String.init) ?? ""
        }

        func has(_ name: String) -> Bool {
            annotations.range(of: "@\(name)\\b", options: .regularExpression) != nil
        }
    }

    private static func annotationMatches(in source: String) -> [(range: Range<String.Index>, annotation: Annotation)] {
        let pattern = #"\b(Request|Get|Post|Put|Patch|Delete)Mapping\b(\s*\(((?:[^()]|\([^()]*\))*)\))?"#
        return matches(in: source, pattern: pattern).map { result in
            let rawName = text(of: result[1], in: source)
            let arguments = result.count > 3 ? text(of: result[3], in: source) : ""
            var httpMethod: HTTPMethod
            switch rawName {
            case "GetMapping": httpMethod = .get
            case "PostMapping": httpMethod = .post
            case "PutMapping": httpMethod = .put
            case "PatchMapping": httpMethod = .patch
            case "DeleteMapping": httpMethod = .delete
            default:
                let value = arguments
                let explicit = ["GET", "POST", "PUT", "PATCH", "DELETE"].first { value.contains("RequestMethod.\($0)") }
                httpMethod = HTTPMethod(rawValue: explicit ?? "GET") ?? .get
            }
            return (
                range: result[0]!,
                annotation: Annotation(name: rawName, value: arguments, httpMethod: httpMethod)
            )
        }
    }

    private static func lastAnnotation(named name: String, in source: String) -> Annotation? {
        let matches = matches(in: source, pattern: #"\b\#(name)\b(\s*\(((?:[^()]|\([^()]*\))*)\))?"#)
        guard let result = matches.last else { return nil }
        let arguments = result.count > 2 ? text(of: result[2], in: source) : ""
        return Annotation(name: name, value: arguments, httpMethod: .get)
    }

    private static func methodSignature(in source: String) -> MethodSignature? {
        let pattern = #"\b(?:public|protected|private)\b[^;(){}]*\(((?:[^()]|\([^()]*\))*)\)\s*(?:throws\s+[^{;]+)?\s*\{"#
        guard let result = matches(in: source, pattern: pattern).first else { return nil }

        let matchedSignature = String(source[result[0]!])
        guard let openParen = matchedSignature.firstIndex(of: "(") else { return nil }
        let declaration = matchedSignature[matchedSignature.startIndex..<openParen]
        let words = declaration.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        guard let name = words.last else { return nil }

        let parameterText = text(of: result[1], in: source)
        return MethodSignature(name: String(name), parameters: splitParameters(parameterText).map(parseParameter))
    }

    private static func splitParameters(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var angleDepth = 0
        var parenDepth = 0

        for character in text {
            switch character {
            case "<": angleDepth += 1
            case ">": angleDepth = max(0, angleDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "," where angleDepth == 0 && parenDepth == 0:
                pieces.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        pieces.append(current)
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func parseParameter(_ raw: String) -> Parameter {
        let pattern = #"(@\w+\s*(?:\(((?:[^()]|\([^()]*\))*)\))?)"#
        var annotations = ""
        var declaration = raw
        for result in matches(in: raw, pattern: pattern).reversed() {
            annotations = text(of: result[1], in: raw) + " " + annotations
            declaration.replaceSubrange(result[0]!, with: " ")
        }
        return Parameter(annotations: annotations, declaration: declaration.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 路径与文本工具

    private static func joinPath(_ prefix: String, _ suffix: String) -> String {
        guard !suffix.isEmpty else {
            let normalizedPrefix = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            return normalizedPrefix.isEmpty ? "/" : normalizedPrefix
        }
        let left = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let right = suffix.hasPrefix("/") ? suffix : "/" + suffix
        let joined = left + right
        return joined == "/" ? "/" : joined
    }

    private static func normalizePath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private static func pathVariables(in path: String) -> [String] {
        matches(in: path, pattern: #"\{([^}:]+)"#).compactMap { text(of: $0[1], in: path).trimmingCharacters(in: .whitespaces) }
    }

    private static func firstPath(_ annotationValue: String) -> String {
        let strings = strings(in: annotationValue)
        if let assigned = firstCapture(
            in: annotationValue,
            pattern: #"\b(?:value|path)\s*=\s*"([^"]+)""#
        ), !assigned.isEmpty {
            return assigned
        }
        return strings.first ?? ""
    }

    private static func firstString(in source: String) -> String? {
        strings(in: source).first
    }

    private static func strings(in source: String) -> [String] {
        matches(in: source, pattern: #""(?:[^"\\]|\\.)*""#).map {
            text(of: $0[0], in: source)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
    }

    private static func firstCapture(in source: String, pattern: String) -> String? {
        matches(in: source, pattern: pattern).first.map { text(of: $0[1], in: source) }
    }

    private static func stripComments(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var previous: Character = "\0"

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index) < source.endIndex ? source[source.index(after: index)] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    output.append(character)
                }
            } else if inBlockComment {
                if character == "*" && next == "/" {
                    inBlockComment = false
                    index = source.index(after: index)
                }
                if character == "\n" { output.append(character) }
            } else if inString {
                output.append(character)
                if character == "\\" {
                    if let next {
                        output.append(next)
                        index = source.index(after: index)
                    }
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "/" && next == "/" {
                inLineComment = true
                index = source.index(after: index)
            } else if character == "/" && next == "*" {
                inBlockComment = true
                index = source.index(after: index)
            } else {
                output.append(character)
                if character == "\"" { inString = true }
            }

            previous = character
            index = source.index(after: index)
        }
        _ = previous
        return output
    }

    private struct RegexMatch {
        let range: Range<String.Index>
        let groups: [Range<String.Index>?]

        subscript(_ index: Int) -> Range<String.Index>? {
            index == 0 ? range : groups[index - 1]
        }

        var count: Int { groups.count + 1 }
    }

    private static func matches(
        in source: String,
        pattern: String
    ) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: nsRange).map { result in
            let range = Range(result.range, in: source)!
            let groups = (1..<result.numberOfRanges).map { group in
                result.range(at: group).location != NSNotFound ? Range(result.range(at: group), in: source) : nil
            }
            return RegexMatch(range: range, groups: groups)
        }
    }

    private static func text(of range: Range<String.Index>?, in source: String) -> String {
        guard let range else { return "" }
        return String(source[range])
    }
}
