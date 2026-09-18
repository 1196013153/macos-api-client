import AppKit
import SwiftUI
import ApiClientCore

// MARK: - 图标

/// 统一的图标渲染。尺寸 / 字重 / 颜色全部走规范，避免各视图各写一套。
struct AppIcon: View {
    let symbol: String
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    var tint: Color = DS.color.textSecondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
    }
}

// MARK: - 按钮样式
//
// 四种角色 × 两种尺寸，全部带悬停 / 按下 / 禁用反馈。
// prominent = 主操作（发送），tinted = 品牌浅底，normal = 次要操作，destructive = 危险操作。

struct AppButtonStyle: ButtonStyle {
    enum Kind {
        case prominent
        case tinted
        case normal
        case destructive
        case ghost
    }

    enum Size {
        case small
        case regular

        var height: CGFloat { self == .small ? 22 : 28 }
        var horizontalPadding: CGFloat { self == .small ? DS.space.md : DS.space.lg }
        var font: Font { self == .small ? DS.font.captionMedium : DS.font.bodyMedium }
        var iconSize: CGFloat { self == .small ? 10 : 11 }
    }

    var kind: Kind = .normal
    var size: Size = .regular
    /// 覆盖强调色（例如「取消发送」用危险色）。
    var tint: Color?
    /// 覆盖默认高度（地址栏这类需要和输入框严格对齐的地方）。
    var height: CGFloat?

    init(kind: Kind = .normal, size: Size = .regular, tint: Color? = nil, height: CGFloat? = nil) {
        self.kind = kind
        self.size = size
        self.tint = tint
        self.height = height
    }

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, kind: kind, size: size, tint: tint, height: height)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        let tint: Color?
        let height: CGFloat?

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        private var accent: Color { tint ?? DS.color.brand }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
        }

        var body: some View {
            configuration.label
                .font(size.font)
                .foregroundStyle(foreground)
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: height ?? size.height)
                .background(shape.fill(background))
                .overlay(shape.strokeBorder(strokeColor, lineWidth: strokeWidth))
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.38)
                .animation(reduceMotion ? nil : DS.motion.press, value: configuration.isPressed)
                .animation(reduceMotion ? nil : DS.motion.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .prominent: return .white
            case .tinted: return accent
            case .destructive: return DS.color.danger
            case .normal, .ghost: return DS.color.textPrimary
            }
        }

        private var background: Color {
            switch kind {
            case .prominent:
                return isHovering ? accent.opacity(0.88) : accent
            case .tinted:
                return isHovering ? accent.opacity(0.20) : accent.opacity(0.12)
            case .destructive:
                return isHovering ? DS.color.dangerSoft : .clear
            case .normal:
                return isHovering ? DS.color.rowHover : DS.color.field
            case .ghost:
                return isHovering ? DS.color.rowHover : .clear
            }
        }

        private var strokeColor: Color {
            switch kind {
            case .prominent, .tinted, .destructive, .ghost: return .clear
            case .normal: return DS.color.hairline
            }
        }

        private var strokeWidth: CGFloat { kind == .normal ? 1 : 0 }
    }
}

/// 图标按钮：正方形热区，悬停时浮出圆形底。
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var tint: Color = DS.color.textSecondary
    var hoverTint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, size: size, tint: tint, hoverTint: hoverTint)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let size: CGFloat
        let tint: Color
        let hoverTint: Color?

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering ? (hoverTint ?? DS.color.textPrimary) : tint)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(isHovering ? DS.color.rowHover : .clear)
                )
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .animation(reduceMotion ? nil : DS.motion.press, value: configuration.isPressed)
                .animation(reduceMotion ? nil : DS.motion.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

/// 整行可点（侧边栏节点、标签页）——按下时轻微回弹，不做背景处理。
struct PressableRowStyle: ButtonStyle {
    var scale: CGFloat = 0.985

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, scale: scale)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let scale: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .animation(reduceMotion ? nil : DS.motion.press, value: configuration.isPressed)
        }
    }
}

// MARK: - 行交互态

/// 列表行的悬停 / 选中背景。用 overlay 叠加而不是直接改背景，
/// 这样在任意底色（侧边栏材质、表格斑马纹）上都能稳定工作。
struct RowHighlight: ViewModifier {
    var isSelected: Bool = false
    var cornerRadius: CGFloat = DS.radius.sm
    var horizontalInset: CGFloat = DS.space.xs
    /// 调用方自己已经在跟踪悬停时传进来，避免同一行装两个 tracking area。
    var externalHover: Bool?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var hovering: Bool { externalHover ?? isHovering }

    @ViewBuilder
    func body(content: Content) -> some View {
        let highlighted = content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
                    .padding(.horizontal, horizontalInset)
            }
            .animation(reduceMotion ? nil : DS.motion.hover, value: hovering)
            .animation(reduceMotion ? nil : DS.motion.select, value: isSelected)

        if externalHover == nil {
            highlighted.onHover { isHovering = $0 }
        } else {
            highlighted
        }
    }

    private var fillColor: Color {
        if isSelected { return DS.color.rowSelected }
        return hovering ? DS.color.rowHover : .clear
    }
}

extension View {
    func rowHighlight(
        isSelected: Bool = false,
        cornerRadius: CGFloat = DS.radius.sm,
        horizontalInset: CGFloat = DS.space.xs,
        hovering: Bool? = nil
    ) -> some View {
        modifier(RowHighlight(
            isSelected: isSelected,
            cornerRadius: cornerRadius,
            horizontalInset: horizontalInset,
            externalHover: hovering
        ))
    }
}

// MARK: - 输入框

/// 内嵌式输入框外观：焦点时描边变成品牌色并轻微加粗。
struct FieldChrome: ViewModifier {
    var isFocused: Bool = false
    var height: CGFloat = 28
    var monospaced: Bool = false
    var horizontalPadding: CGFloat = DS.space.md

    func body(content: Content) -> some View {
        content
            .font(monospaced ? DS.font.mono : DS.font.body)
            .textFieldStyle(.plain)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                    .fill(isFocused ? DS.color.fieldFocused : DS.color.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
                    .strokeBorder(isFocused ? DS.color.brand : DS.color.hairline, lineWidth: 1)
            )
            .animation(DS.motion.hover, value: isFocused)
    }
}

extension View {
    func fieldChrome(
        isFocused: Bool = false,
        height: CGFloat = 28,
        monospaced: Bool = false,
        horizontalPadding: CGFloat = DS.space.md
    ) -> some View {
        modifier(FieldChrome(
            isFocused: isFocused,
            height: height,
            monospaced: monospaced,
            horizontalPadding: horizontalPadding
        ))
    }
}

// MARK: - 加载指示

/// 细环形加载指示。比 ProgressView 更轻，且在深色按钮上对比度可控。
struct SpinnerDot: View {
    var color: Color = DS.color.brand
    var size: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.4, size * 0.14), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                reduceMotion ? nil : .linear(duration: 0.72).repeatForever(autoreverses: false),
                value: isSpinning
            )
            .onAppear { isSpinning = true }
    }
}

// MARK: - 徽标

/// HTTP 方法徽标：浅底药丸 + 方法色文字。
struct MethodBadge: View {
    let method: HTTPMethod
    var compact: Bool = false

    var body: some View {
        Text(method.rawValue)
            .font(compact ? DS.font.badgeSmall : DS.font.badge)
            .foregroundStyle(method.tint)
            .padding(.horizontal, compact ? 4 : 5)
            .padding(.vertical, 1.5)
            .background(method.softTint, in: RoundedRectangle(cornerRadius: DS.radius.xs, style: .continuous))
            .frame(width: compact ? 40 : 48, alignment: .leading)
    }
}

/// 计数 / 状态小胶囊。
struct CountBadge: View {
    let text: String
    var tint: Color = DS.color.textSecondary

    var body: some View {
        Text(text)
            .font(DS.font.micro)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(DS.color.field, in: Capsule())
    }
}

/// 带图标的指标（耗时、大小、Content-Type）。
struct MetaChip: View {
    let symbol: String
    let text: String
    var tint: Color = DS.color.textSecondary
    var help: String?

    var body: some View {
        HStack(spacing: DS.space.xs) {
            AppIcon(symbol: symbol, size: 9, tint: tint)
            Text(text)
                .font(DS.font.monoSmall)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .help(help ?? text)
    }
}

/// 状态码徽标。
struct StatusBadge: View {
    let code: Int
    let text: String
    var failed: Bool = false

    private var tint: Color {
        failed ? DS.color.danger : StatusPalette.color(for: code)
    }

    private var soft: Color {
        failed ? DS.color.dangerSoft : StatusPalette.soft(for: code)
    }

    var body: some View {
        HStack(spacing: DS.space.sm) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(failed ? "请求失败" : "\(code)")
                .font(DS.font.status)
                .foregroundStyle(tint)
            if !text.isEmpty, !failed {
                Text(text)
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textSecondary)
            }
        }
        .padding(.horizontal, DS.space.md)
        .padding(.vertical, 3)
        .background(soft, in: Capsule())
        .animation(DS.motion.select, value: code)
    }
}

/// 未保存 / 草稿标记。
struct DirtyDot: View {
    var tint: Color = DS.color.warning

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
    }
}

// MARK: - 分区切换（带滑动指示条）

/// 请求编辑器 / 响应面板顶部的分区切换。指示条用 matchedGeometryEffect 滑动，
/// 比每条各画一条下划线更连贯。
struct SectionTabBar<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    var badge: (Item) -> String? = { _ in nil }
    var accent: (Item) -> Color? = { _ in nil }
    @Binding var selection: Item

    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.space.hair) {
            ForEach(items) { item in
                tab(for: item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.space.xs)
    }

    private func tab(for item: Item) -> some View {
        let isActive = selection == item
        let itemAccent = accent(item) ?? DS.color.brand

        return Button {
            guard !isActive else { return }
            selection = item
        } label: {
            HStack(spacing: DS.space.sm) {
                Text(title(item))
                    .font(isActive ? DS.font.captionMedium : DS.font.caption)
                if let text = badge(item) {
                    Text(text)
                        .font(DS.font.micro)
                        .foregroundStyle(isActive ? itemAccent : DS.color.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(
                            isActive ? itemAccent.opacity(0.14) : DS.color.field,
                            in: Capsule()
                        )
                }
            }
            .foregroundStyle(isActive ? DS.color.textPrimary : DS.color.textSecondary)
            .padding(.horizontal, DS.space.lg)
            .frame(height: DS.metric.barHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if isActive {
                    Capsule()
                        .fill(itemAccent)
                        .frame(height: 2)
                        .matchedGeometryEffect(id: "sectionIndicator", in: indicator)
                }
            }
        }
        .buttonStyle(PressableRowStyle(scale: 0.96))
        .animation(reduceMotion ? nil : DS.motion.select, value: selection)
    }
}

// MARK: - 可滚动的分段条

/// 和 `SectionTabBar` 的区别：项数多、宽度不够时可以横向滚动，
/// 而且**选中项变化时会自动把它滚进视野**（「自动定位到当前方式所在的位置」就靠它）。
struct ChipTabBar<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    var symbol: (Item) -> String? = { _ in nil }
    var accent: (Item) -> Color? = { _ in nil }
    @Binding var selection: Item

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Item?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.space.xs) {
                    ForEach(items) { item in
                        chip(item).id(item.id)
                    }
                }
                .padding(.horizontal, DS.space.xs)
                // 上下留一点空隙，让 chip 的描边不被裁掉
                .padding(.vertical, DS.space.xs)
            }
            .onAppear { proxy.scrollTo(selection.id, anchor: .center) }
            .onChange(of: selection) { _, newValue in
                withAnimation(reduceMotion ? nil : DS.motion.select) {
                    proxy.scrollTo(newValue.id, anchor: .center)
                }
            }
        }
    }

    private func chip(_ item: Item) -> some View {
        let isActive = selection == item
        let itemAccent = accent(item) ?? DS.color.brand
        let isHovering = hovered == item

        return Button {
            guard !isActive else { return }
            selection = item
        } label: {
            HStack(spacing: DS.space.sm) {
                if let name = symbol(item) {
                    AppIcon(
                        symbol: name,
                        size: 9,
                        weight: .semibold,
                        tint: isActive ? itemAccent : DS.color.textTertiary
                    )
                }
                Text(title(item))
                    .font(isActive ? DS.font.captionMedium : DS.font.caption)
                    .foregroundStyle(isActive ? DS.color.textPrimary : DS.color.textSecondary)
            }
            .padding(.horizontal, DS.space.lg)
            .frame(height: 24)
            .background(
                isActive
                    ? itemAccent.opacity(0.13)
                    : (isHovering ? DS.color.rowHover : DS.color.field.opacity(0.7)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(isActive ? itemAccent.opacity(0.45) : .clear, lineWidth: 1)
            )
            .contentShape(Capsule())
            // 不加 fixedSize，横向 ScrollView 会把可压缩的文本「压扁」而不是让内容溢出：
            // 方式一多，最后一个 chip 就会被截断成半截字（Form-data → Form）。
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(PressableRowStyle(scale: 0.96))
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .animation(reduceMotion ? nil : DS.motion.hover, value: isHovering)
        .animation(reduceMotion ? nil : DS.motion.select, value: isActive)
    }
}

// MARK: - 可点芯片

/// 操作栏里「可点的芯片」（Mock 开关 / 地址预览 / 环境菜单 / 方法菜单）的统一外观。
///
/// 这些入口本质上都是按钮，但此前没有悬停反馈，形状也一个胶囊一个圆角矩形。
/// 统一交给这个组件：圆角矩形、悬停加深、激活态浅底 + 描边。
struct HoverChip<Content: View>: View {
    var isActive: Bool = false
    var accent: Color = DS.color.brand
    var height: CGFloat = 24
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.radius.sm, style: .continuous)
    }

    var body: some View {
        content
            .padding(.horizontal, DS.space.md)
            .frame(height: height)
            .background(shape.fill(background))
            .overlay(
                shape.strokeBorder(
                    isActive ? accent.opacity(isHovering ? 0.55 : 0.35) : Color.clear,
                    lineWidth: 1
                )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : DS.motion.hover, value: isHovering)
    }

    private var background: Color {
        if isActive {
            return isHovering ? accent.opacity(0.20) : accent.opacity(0.12)
        }
        return isHovering ? DS.color.rowHover : DS.color.field
    }
}

// MARK: - 骨架屏

/// 加载占位块，带扫光。减少动态效果时退化为静态灰块。
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10
    var cornerRadius: CGFloat = DS.radius.xs

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.7

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(DS.color.field)
            .frame(width: width, height: height)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, DS.color.surface.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(geometry.size.width * 0.45, 24))
                        .offset(x: phase * geometry.size.width)
                    }
                    .clipShape(shape)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(DS.motion.shimmer) { phase = 1.5 }
            }
    }
}

/// 请求进行中的骨架：模拟响应体的行块。
struct ResponseSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.space.lg) {
            SkeletonBlock(width: 120, height: 12)
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: DS.space.md) {
                    SkeletonBlock(width: 92, height: 10)
                    SkeletonBlock(height: 10)
                        .frame(maxWidth: .infinity)
                }
                .padding(.leading, CGFloat(index % 2) * DS.space.lg)
            }
            SkeletonBlock(width: 200, height: 10)
        }
        .padding(DS.space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 提示条

/// 底部浮出提示。成功 / 失败用图标 + 语义色区分。
struct ToastView: View {
    let notice: AppStore.Notice
    let onDismiss: () -> Void

    private var isError: Bool { notice.level == .error }
    private var tint: Color { isError ? DS.color.danger : DS.color.success }

    var body: some View {
        HStack(spacing: DS.space.md) {
            AppIcon(
                symbol: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                size: 13,
                tint: tint
            )

            Text(notice.text)
                .font(DS.font.body)
                .foregroundStyle(DS.color.textPrimary)
                .lineLimit(2)

            Button(action: onDismiss) {
                AppIcon(symbol: "xmark", size: 9, weight: .bold, tint: DS.color.textTertiary)
            }
            .buttonStyle(IconButtonStyle(size: 20, tint: DS.color.textTertiary))
        }
        .padding(.leading, DS.space.lg)
        .padding(.trailing, DS.space.sm)
        .padding(.vertical, DS.space.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.color.border))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}

// MARK: - 容器

/// 卡片容器：统一圆角、描边与留白。
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = DS.space.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous)
                    .fill(DS.color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radius.lg, style: .continuous)
                    .strokeBorder(DS.color.hairline)
            )
    }
}

/// 分节标题（表单、设置页用）。
struct SectionLabel: View {
    let text: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space.hair) {
            Text(text)
                .font(DS.font.captionMedium)
                .foregroundStyle(DS.color.textSecondary)
            if let detail {
                Text(detail)
                    .font(DS.font.caption)
                    .foregroundStyle(DS.color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 键值并排的信息行（请求详情、项目信息）。
struct DetailRow: View {
    let name: String
    let value: String
    var monospaced: Bool = false
    var nameWidth: CGFloat = 118

    var body: some View {
        HStack(alignment: .top, spacing: DS.space.md) {
            Text(name)
                .font(DS.font.captionMedium)
                .foregroundStyle(DS.color.textSecondary)
                .frame(width: nameWidth, alignment: .leading)
            Text(value)
                .font(monospaced ? DS.font.monoSmall : DS.font.body)
                .foregroundStyle(DS.color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
