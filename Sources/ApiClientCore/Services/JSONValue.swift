import Foundation

/// 保序 JSON 模型。
///
/// 不使用 `JSONSerialization` 的原因：
/// 1. 字典会丢失服务端返回的字段顺序；
/// 2. 数字统一转 `Double`，`1234567890123456789` 这类雪花 ID 会变成科学计数法并丢精度。
/// 这里把数字按原始字面量保存，接口调试时看到什么就是什么。
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// 保留原始数字字面量（如 `1.0` / `1234567890123456789`）。
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONEntry])

    public var isContainer: Bool {
        switch self {
        case .array, .object: return true
        default: return false
        }
    }

    /// 折叠状态下的摘要文本，如 `{…} 3 个字段` / `[…] 5 项`。
    public var summary: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let literal): return literal
        case .string(let value): return "\"\(value)\""
        case .array(let items): return "[\(items.count) 项]"
        case .object(let entries): return "{\(entries.count) 个字段}"
        }
    }

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    public var childCount: Int {
        switch self {
        case .array(let items): return items.count
        case .object(let entries): return entries.count
        default: return 0
        }
    }

    /// 重新序列化（保持字段顺序），用于「格式化」。
    public func prettyPrinted(indent: Int = 2) -> String {
        var output = ""
        write(into: &output, level: 0, indent: indent)
        return output
    }

    private func write(into output: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: level * indent)
        let childPad = String(repeating: " ", count: (level + 1) * indent)

        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let literal):
            output += literal
        case .string(let value):
            output += JSONValue.escape(value)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "[\n"
            for (index, item) in items.enumerated() {
                output += childPad
                item.write(into: &output, level: level + 1, indent: indent)
                output += index == items.count - 1 ? "\n" : ",\n"
            }
            output += pad + "]"
        case .object(let entries):
            if entries.isEmpty { output += "{}"; return }
            output += "{\n"
            for (index, entry) in entries.enumerated() {
                output += childPad + JSONValue.escape(entry.key) + ": "
                entry.value.write(into: &output, level: level + 1, indent: indent)
                output += index == entries.count - 1 ? "\n" : ",\n"
            }
            output += pad + "}"
        }
    }

    private static func escape(_ value: String) -> String {
        var result = "\""
        for character in value {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if let ascii = character.asciiValue, ascii < 0x20 {
                    result += String(format: "\\u%04x", ascii)
                } else {
                    result.append(character)
                }
            }
        }
        return result + "\""
    }
}

public struct JSONEntry: Hashable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

// MARK: - 解析

public enum JSONValueParser {
    public static func parse(_ text: String) -> JSONValue? {
        var parser = JSONScanner(scalars: Array(text.unicodeScalars))
        return parser.parseValue()
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }
}

private struct JSONScanner {
    let scalars: [UnicodeScalar]
    var index: Int = 0

    var current: UnicodeScalar? { index < scalars.count ? scalars[index] : nil }

    mutating func skipWhitespace() {
        while let scalar = current, scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" {
            index += 1
        }
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let scalar = current else { return nil }
        switch scalar {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { JSONValue.string($0) }
        case "t": return consume("true") ? .bool(true) : nil
        case "f": return consume("false") ? .bool(false) : nil
        case "n": return consume("null") ? .null : nil
        default: return parseNumber().map { JSONValue.number($0) }
        }
    }

    private mutating func consume(_ literal: String) -> Bool {
        let target = Array(literal.unicodeScalars)
        guard index + target.count <= scalars.count else { return false }
        for offset in 0..<target.count where scalars[index + offset] != target[offset] {
            return false
        }
        index += target.count
        return true
    }

    private mutating func parseObject() -> JSONValue? {
        index += 1 // {
        var entries: [JSONEntry] = []
        skipWhitespace()
        if current == "}" {
            index += 1
            return .object(entries)
        }
        while true {
            skipWhitespace()
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard current == ":" else { return nil }
            index += 1
            guard let value = parseValue() else { return nil }
            entries.append(JSONEntry(key: key, value: value))
            skipWhitespace()
            if current == "," {
                index += 1
                continue
            }
            if current == "}" {
                index += 1
                return .object(entries)
            }
            return nil
        }
    }

    private mutating func parseArray() -> JSONValue? {
        index += 1 // [
        var items: [JSONValue] = []
        skipWhitespace()
        if current == "]" {
            index += 1
            return .array(items)
        }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            if current == "," {
                index += 1
                continue
            }
            if current == "]" {
                index += 1
                return .array(items)
            }
            return nil
        }
    }

    private mutating func parseString() -> String? {
        guard current == "\"" else { return nil }
        index += 1
        var result = String.UnicodeScalarView()

        while let scalar = current {
            if scalar == "\"" {
                index += 1
                return String(result)
            }
            if scalar == "\\" {
                index += 1
                guard let escape = current else { return nil }
                index += 1
                switch escape {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append(UnicodeScalar(8))
                case "f": result.append(UnicodeScalar(12))
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    guard var code = parseHex4() else { return nil }
                    // UTF-16 代理对
                    if code >= 0xD800, code <= 0xDBFF {
                        let checkpoint = index
                        if current == "\\" {
                            index += 1
                            if current == "u" {
                                index += 1
                                if let low = parseHex4(), low >= 0xDC00, low <= 0xDFFF {
                                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                                } else {
                                    index = checkpoint
                                }
                            } else {
                                index = checkpoint
                            }
                        }
                    }
                    result.append(UnicodeScalar(code) ?? "\u{FFFD}")
                default:
                    return nil
                }
            } else {
                result.append(scalar)
                index += 1
            }
        }
        return nil
    }

    private mutating func parseHex4() -> UInt32? {
        guard index + 4 <= scalars.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = scalars[index].hexDigitValue else { return nil }
            value = value * 16 + UInt32(digit)
            index += 1
        }
        return value
    }

    private mutating func parseNumber() -> String? {
        let start = index
        while let scalar = current, scalar.isNumberCharacter {
            index += 1
        }
        guard index > start else { return nil }
        return String(String.UnicodeScalarView(scalars[start..<index]))
    }
}

private extension UnicodeScalar {
    /// 十六进制数字值（0-9 / a-f / A-F）。
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 48)
        case "a"..."f": return Int(value - 87)
        case "A"..."F": return Int(value - 55)
        default: return nil
        }
    }

    var isNumberCharacter: Bool {
        switch self {
        case "0"..."9", "-", "+", ".", "e", "E": return true
        default: return false
        }
    }
}
