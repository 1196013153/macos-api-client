import AppKit
import SwiftUI
import ApiClientCore

// MARK: - 设计令牌
//
// 全应用唯一的视觉规范来源。任何视图都不应再出现裸数字（间距、圆角、字号）
// 或临时拼出来的颜色，一律从这里取。
//
// 所有颜色都通过 NSColor 动态 provider 定义，随系统外观自动切换，
// 不需要在视图里判断深浅色。

enum DS {

    // MARK: 颜色

    enum color {
        /// 窗口底色
        static let canvas = Color(nsColor: .windowBackgroundColor)
        /// 面板 / 卡片
        static let surface = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x1F1F22))
        /// 下沉区域（编辑器、代码块）
        static let sunken = dynamic(light: rgb(0xFAFAFC), dark: rgb(0x17171A))
        /// 输入框、内嵌字段
        static let field = dynamic(light: rgb(0xF1F2F5), dark: rgb(0x2A2A2E))
        /// 输入框获得焦点时的底色
        static let fieldFocused = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x232327))

        /// 极细分隔线
        static let hairline = dynamic(light: rgba(0x000000, 0.07), dark: rgba(0xFFFFFF, 0.07))
        /// 常规描边
        static let border = dynamic(light: rgba(0x000000, 0.11), dark: rgba(0xFFFFFF, 0.11))

        /// 文本
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        /// 第三层文本。不用系统的 `tertiaryLabelColor`：它约 25% 不透明度，
        /// 在本应用的面板底色上只有约 2.3:1，远低于 WCAG AA 的 4.5:1。
        /// 这里压到刚好越过 AA，同时仍明显弱于 secondary，保住「主 > 次 > 辅」三层层级。
        static let textTertiary = dynamic(light: rgba(0x000000, 0.54), dark: rgba(0xFFFFFF, 0.46))

        /// 品牌主色（发送按钮、品牌标记、焦点环）
        static let brand = dynamic(light: rgb(0x3D6BF5), dark: rgb(0x6E96FF))
        /// 品牌色低透明度底
        static let brandSoft = dynamic(light: rgba(0x3D6BF5, 0.10), dark: rgba(0x6E96FF, 0.18))
        /// 品牌渐变（仅用于品牌标记）
        static let brandGradientStart = dynamic(light: rgb(0x4A7BF7), dark: rgb(0x7BA2FF))
        static let brandGradientEnd = dynamic(light: rgb(0x6B4BDE), dark: rgb(0x9B7BF0))

        /// 语义色
        static let success = dynamic(light: rgb(0x1E9E5A), dark: rgb(0x41C57F))
        static let warning = dynamic(light: rgb(0xD9820B), dark: rgb(0xF0A93B))
        static let danger = dynamic(light: rgb(0xD93A3A), dark: rgb(0xF07070))
        static let info = dynamic(light: rgb(0x2E7BE0), dark: rgb(0x6EA8FF))

        /// 语义色的浅底
        static let successSoft = dynamic(light: rgba(0x1E9E5A, 0.12), dark: rgba(0x41C57F, 0.16))
        static let warningSoft = dynamic(light: rgba(0xD9820B, 0.13), dark: rgba(0xF0A93B, 0.16))
        static let dangerSoft = dynamic(light: rgba(0xD93A3A, 0.11), dark: rgba(0xF07070, 0.16))
        static let infoSoft = dynamic(light: rgba(0x2E7BE0, 0.12), dark: rgba(0x6EA8FF, 0.16))

        /// 行交互态
        static let rowHover = dynamic(light: rgba(0x000000, 0.045), dark: rgba(0xFFFFFF, 0.055))
        static let rowSelected = dynamic(light: rgba(0x3D6BF5, 0.13), dark: rgba(0x6E96FF, 0.20))
        /// 表格斑马纹
        static let zebra = dynamic(light: rgba(0x000000, 0.016), dark: rgba(0xFFFFFF, 0.02))

        /// 让内容整体略微提亮的浮层（标签 chip 选中态）
        static let elevated = dynamic(light: rgb(0xFFFFFF), dark: rgb(0x303036))

        // JSON 语法着色。取一组在浅色/深色下都能保持足够对比、且不会与语义色混淆的色相。
        // 取值都在 nsColor 里定义一份，代码编辑器（NSTextView）与 SwiftUI 共用同一套色。
        static let syntaxKey = Color(nsColor: nsColor.syntaxKey)
        static let syntaxString = Color(nsColor: nsColor.syntaxString)
        static let syntaxNumber = Color(nsColor: nsColor.syntaxNumber)
        static let syntaxBool = Color(nsColor: nsColor.syntaxBool)
        static let syntaxNull = Color(nsColor: nsColor.syntaxNull)
        static let syntaxPunctuation = Color(nsColor: nsColor.syntaxPunctuation)
    }

    // MARK: 颜色（AppKit 侧）
    //
    // 代码编辑器用的是 NSTextView，属性字符串只认 NSColor。
    // 这里放同一套颜色的 NSColor 版本，避免「SwiftUI 一份、AppKit 又抄一份」而慢慢走样。

    enum nsColor {
        static let textPrimary = NSColor.labelColor
        /// 与 SwiftUI 侧 `DS.color.textTertiary` 同一档对比度（代码编辑器的行号等用它）。
        static let textTertiary = dynamicNS(light: rgba(0x000000, 0.54), dark: rgba(0xFFFFFF, 0.46))

        static let syntaxKey = dynamicNS(light: rgb(0x0B5CAD), dark: rgb(0x7FB3FF))
        static let syntaxString = dynamicNS(light: rgb(0xB4531F), dark: rgb(0xE8A87C))
        static let syntaxNumber = dynamicNS(light: rgb(0x1F6FEB), dark: rgb(0x7CB0FF))
        static let syntaxBool = dynamicNS(light: rgb(0x8250DF), dark: rgb(0xC09BFF))
        static let syntaxNull = dynamicNS(light: rgb(0x6E7781), dark: rgb(0x8B949E))
        static let syntaxPunctuation = dynamicNS(light: rgb(0x8C959F), dark: rgb(0x6E7681))
    }

    // MARK: 间距（4 的倍数体系）

    enum space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 24
        static let huge: CGFloat = 32
    }

    // MARK: 圆角

    enum radius {
        /// 极小的装饰圆角（项目标签的指示条等）
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 14
        static let pill: CGFloat = 999
    }

    // MARK: 字体

    enum font {
        static let title = Font.system(size: 15, weight: .semibold)
        static let heading = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 12)
        static let bodyMedium = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11)
        static let captionMedium = Font.system(size: 11, weight: .medium)
        static let micro = Font.system(size: 10, weight: .semibold)
        static let metric = Font.system(size: 20, weight: .semibold, design: .rounded)

        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
        static let monoTiny = Font.system(size: 10, design: .monospaced)

        /// HTTP 方法徽标
        static let badge = Font.system(size: 9, weight: .heavy, design: .rounded)
        static let badgeSmall = Font.system(size: 8, weight: .heavy, design: .rounded)
        /// 地址栏的方法选择器
        static let methodPicker = Font.system(size: 12, weight: .heavy, design: .rounded)
        /// 响应状态码数字
        static let status = Font.system(size: 11, weight: .bold, design: .rounded)
    }

    /// AppKit 侧的字体（代码编辑器用 NSTextView，属性字符串只认 NSFont）。
    enum fontNS {
        static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    // MARK: 动效
    //
    // 时长与曲线集中管理：悬停要跟手（<150ms），选中要有一点回弹，
    // 进出场用弹簧让元素"落位"而不是生硬出现。

    enum motion {
        static let hover = Animation.easeOut(duration: 0.12)
        static let press = Animation.easeOut(duration: 0.08)
        static let select = Animation.spring(response: 0.28, dampingFraction: 0.84)
        static let enter = Animation.spring(response: 0.34, dampingFraction: 0.86)
        static let toast = Animation.spring(response: 0.38, dampingFraction: 0.80)
        static let shimmer = Animation.linear(duration: 1.15).repeatForever(autoreverses: false)
    }

    // MARK: 尺寸

    enum metric {
        static let sidebarMin: CGFloat = 230
        static let sidebarIdeal: CGFloat = 292
        static let sidebarMax: CGFloat = 460
        static let listRow: CGFloat = 26
        static let kvRow: CGFloat = 28
        static let barHeight: CGFloat = 36
        static let tabHeight: CGFloat = 30
        static let tabStripHeight: CGFloat = 40
        static let projectTabHeight: CGFloat = 24
        static let projectTabStripHeight: CGFloat = 34
        static let headerHeight: CGFloat = 46
        static let contentPadding: CGFloat = 12
        /// 侧边栏树每层缩进
        static let treeIndent: CGFloat = 13
    }

    // MARK: 品牌标记尺寸

    enum brand {
        static let markSize: CGFloat = 22
    }
}

// MARK: - 颜色工具

private func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func rgba(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
    rgb(hex, alpha)
}

private func dynamicNS(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.isDark ? dark : light
    }
}

private func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: dynamicNS(light: light, dark: dark))
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - 领域模型 → 视觉映射

extension HTTPMethod {
    /// 方法色：GET 绿 / POST 橙 / PUT 蓝 / PATCH 紫 / DELETE 红。
    var tint: Color {
        switch self {
        case .get: return DS.color.success
        case .post: return DS.color.warning
        case .put: return DS.color.info
        case .patch: return dynamic(light: rgb(0x8B5CF6), dark: rgb(0xA78BFA))
        case .delete: return DS.color.danger
        case .head, .options: return DS.color.textSecondary
        }
    }

    /// 方法色的浅底，用于徽标背景
    var softTint: Color {
        switch self {
        case .get: return DS.color.successSoft
        case .post: return DS.color.warningSoft
        case .put: return DS.color.infoSoft
        case .patch: return dynamic(light: rgba(0x8B5CF6, 0.12), dark: rgba(0xA78BFA, 0.16))
        case .delete: return DS.color.dangerSoft
        case .head, .options: return DS.color.field
        }
    }
}

extension ParamLocation {
    var title: String {
        switch self {
        case .query: return "query"
        case .path: return "path"
        case .header: return "header"
        }
    }
}

extension RequestBodyKind {
    var title: String {
        switch self {
        case .none: return "无"
        case .json: return "JSON"
        case .raw: return "Raw"
        case .formURLEncoded: return "Form"
        case .formData: return "Form-data"
        }
    }

    /// 完整名称，用于提示气泡
    var fullTitle: String {
        switch self {
        case .none: return "不发送请求体"
        case .json: return "application/json"
        case .raw: return "纯文本"
        case .formURLEncoded: return "application/x-www-form-urlencoded（表单编码）"
        case .formData: return "multipart/form-data（字段可以是文本或本地文件）"
        }
    }
}

/// 状态码 → 语义色
enum StatusPalette {
    static func color(for statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: return DS.color.success
        case 300..<400: return DS.color.info
        case 400..<500: return DS.color.warning
        case 500...: return DS.color.danger
        default: return DS.color.textSecondary
        }
    }

    static func soft(for statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: return DS.color.successSoft
        case 300..<400: return DS.color.infoSoft
        case 400..<500: return DS.color.warningSoft
        case 500...: return DS.color.dangerSoft
        default: return DS.color.field
        }
    }
}
