import AppKit

/// 代码编辑器支持的语言。
enum CodeLanguage: String, Hashable {
    /// JSON：键 / 字符串 / 数字 / 字面量 / 标点分别着色。
    case json
    /// 纯文本：只上基础字体与颜色，不做词法着色。
    case plain
}

/// 词法着色。
///
/// 刻意不做语法校验——只按 token 上色。JSON 里少一个引号、多一个逗号，
/// 颜色会立刻「断掉」，肉眼比报错信息更快发现问题，这也是编辑器高亮的主要价值。
enum CodeTokenizer {

    struct Token {
        var range: NSRange
        var kind: Kind
    }

    enum Kind {
        case key
        case string
        case number
        case literal
        case punctuation
    }

    /// 超过这个长度就不着色了：大响应体全文上色会明显卡顿，而此刻用户更关心的是「能不能快速看完」。
    static let highlightLimit = 200_000

    static func tokens(in text: String, language: CodeLanguage) -> [Token] {
        guard language == .json else { return [] }
        let units = Array(text.utf16)
        guard units.count <= highlightLimit else { return [] }

        var tokens: [Token] = []
        var index = 0

        while index < units.count {
            let unit = units[index]

            switch unit {
            case 0x22: // "
                let start = index
                index += 1
                while index < units.count {
                    let current = units[index]
                    if current == 0x5C { // 反斜杠：跳过被转义的下一个字符
                        index += 2
                        continue
                    }
                    if current == 0x22 { index += 1; break }
                    if current == 0x0A { break } // 字符串没闭合就换行了，别把后面整段吃掉
                    index += 1
                }
                let range = NSRange(location: start, length: min(index, units.count) - start)
                tokens.append(Token(range: range, kind: isKey(after: index, in: units) ? .key : .string))

            case 0x2D, 0x30...0x39: // - 或数字
                let start = index
                while index < units.count, isNumberUnit(units[index]) { index += 1 }
                tokens.append(Token(range: NSRange(location: start, length: index - start), kind: .number))

            case 0x74, 0x66, 0x6E: // t / f / n → true / false / null
                let start = index
                while index < units.count, isLetterUnit(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if word == "true" || word == "false" || word == "null" {
                    tokens.append(Token(range: NSRange(location: start, length: index - start), kind: .literal))
                }

            case 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A: // { } [ ] , :
                tokens.append(Token(range: NSRange(location: index, length: 1), kind: .punctuation))
                index += 1

            default:
                index += 1
            }
        }

        return tokens
    }

    static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .key: return DS.nsColor.syntaxKey
        case .string: return DS.nsColor.syntaxString
        case .number: return DS.nsColor.syntaxNumber
        case .literal: return DS.nsColor.syntaxBool
        case .punctuation: return DS.nsColor.syntaxPunctuation
        }
    }

    // MARK: 内部

    /// 字符串后面跟的是冒号 → 这是一个对象的键，用另一种颜色区分「字段名」和「值」。
    private static func isKey(after index: Int, in units: [UInt16]) -> Bool {
        var cursor = index
        while cursor < units.count, isWhitespaceUnit(units[cursor]) { cursor += 1 }
        return cursor < units.count && units[cursor] == 0x3A
    }

    private static func isNumberUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x2E, 0x2D, 0x2B, 0x65, 0x45: return true
        default: return false
        }
    }

    private static func isLetterUnit(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isWhitespaceUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x20, 0x09, 0x0A, 0x0D: return true
        default: return false
        }
    }
}
