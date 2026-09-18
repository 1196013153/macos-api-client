import Foundation

/// 变量解析上下文。优先级：runtime > environment > globals > dynamic。
public struct VariableContext: Sendable {
    public var environment: [String: String]
    public var globals: [String: String]
    public var runtime: [String: String]
    public var dynamic: [String: String]

    public init(
        environment: [String: String] = [:],
        globals: [String: String] = [:],
        runtime: [String: String] = [:],
        dynamic: [String: String] = [:]
    ) {
        self.environment = environment
        self.globals = globals
        self.runtime = runtime
        self.dynamic = dynamic
    }

    public func value(for name: String) -> String? {
        if let value = runtime[name], !value.isEmpty { return value }
        if let value = environment[name], !value.isEmpty { return value }
        if let value = globals[name], !value.isEmpty { return value }
        if let value = dynamic[name] { return value }
        return nil
    }
}

public struct VariableResolution: Sendable, Equatable {
    public var text: String
    /// 未被替换的变量名（去重、按出现顺序）。发送时用于提示，而不是静默变成空串。
    public var unresolved: [String]

    public init(text: String, unresolved: [String] = []) {
        self.text = text
        self.unresolved = unresolved
    }
}

/// `{{name}}` 变量替换 + 内置动态变量。
public enum VariableResolver {
    private static let regex = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    /// 内置动态变量：每次发送时求值。
    public static func dynamicVariables(
        projectName: String,
        environmentName: String,
        now: Date = Date()
    ) -> [String: String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        formatter.dateFormat = "HH:mm:ss"
        let time = formatter.string(from: now)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let datetime = formatter.string(from: now)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        let isoDate = formatter.string(from: now)

        let seconds = Int(now.timeIntervalSince1970)
        let milliseconds = Int(now.timeIntervalSince1970 * 1000)

        return [
            "$uuid": UUID().uuidString,
            "$timestamp": String(seconds),
            "$timestampMs": String(milliseconds),
            "$date": date,
            "$time": time,
            "$datetime": datetime,
            "$isoDate": isoDate,
            "$date.millisecondsTimestamp": String(milliseconds),
            "$date.secondsTimestamp": String(seconds),
            "$date.year": String(Calendar.current.component(.year, from: now)),
            "$date.month": String(Calendar.current.component(.month, from: now)),
            "$date.day": String(Calendar.current.component(.day, from: now)),
            "$randomInt": String(Int.random(in: 0...100_000)),
            "$randomStr": randomString(length: 8),
            "$projectName": projectName,
            "$envName": environmentName,
        ]
    }

    public static func resolve(_ input: String, context: VariableContext) -> VariableResolution {
        guard input.contains("{{") else {
            return VariableResolution(text: input)
        }

        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        guard !matches.isEmpty else {
            return VariableResolution(text: input)
        }

        var result = ""
        var cursor = 0
        var unresolved: [String] = []

        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += nsInput.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let name = nsInput.substring(with: match.range(at: 1))
            if let value = context.value(for: name) {
                result += value
            } else {
                // 未定义变量原样保留，避免“静默变空”导致的接口诡异失败。
                result += nsInput.substring(with: range)
                if !unresolved.contains(name) { unresolved.append(name) }
            }
            cursor = range.location + range.length
        }

        if cursor < nsInput.length {
            result += nsInput.substring(with: NSRange(location: cursor, length: nsInput.length - cursor))
        }

        return VariableResolution(text: result, unresolved: unresolved)
    }

    /// 便捷方法：只取替换结果。
    public static func text(_ input: String, context: VariableContext) -> String {
        resolve(input, context: context).text
    }

    private static func randomString(length: Int) -> String {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in alphabet.randomElement() ?? "a" })
    }
}
