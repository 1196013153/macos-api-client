import SwiftUI
import ApiClientCore

// MARK: - 品牌标记

/// 应用标记：与应用图标同源的圆角渐变块 + 花括号。
struct BrandMark: View {
    var size: CGFloat = DS.brand.markSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [DS.color.brandGradientStart, DS.color.brandGradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Text("{}")
                    .font(.system(size: size * 0.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .offset(y: -size * 0.02)
            }
            .frame(width: size, height: size)
            .shadow(color: DS.color.brand.opacity(0.25), radius: size * 0.16, y: size * 0.05)
    }
}

// MARK: - 空状态插图
//
// 全部用 Canvas 按固定 140×104 坐标空间矢量绘制：
// 不引入位图资源，任意缩放与深浅色下都清晰，颜色也直接取自设计令牌。

enum EmptyArt {
    /// 没有打开的标签页
    case tabs
    /// 还没有响应
    case response
    /// 搜索无结果
    case search
    /// 项目里还没有接口
    case collection
    /// 请求不携带请求体
    case body
}

struct EmptyArtView: View {
    let kind: EmptyArt
    var size: CGSize = CGSize(width: 140, height: 104)

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width / 140, canvasSize.height / 104)
            context.scaleBy(x: scale, y: scale)
            switch kind {
            case .tabs: EmptyArtDrawing.tabs(&context)
            case .response: EmptyArtDrawing.response(&context)
            case .search: EmptyArtDrawing.search(&context)
            case .collection: EmptyArtDrawing.collection(&context)
            case .body: EmptyArtDrawing.body(&context)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

private enum EmptyArtDrawing {

    static func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }

    static func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: h / 2, style: .continuous)
    }

    /// 堆叠的窗口 + 加号
    static func tabs(_ context: inout GraphicsContext) {
        context.fill(roundedRect(16, 12, 76, 54, 9), with: .color(DS.color.field))

        let front = roundedRect(46, 30, 88, 62, 9)
        context.fill(front, with: .color(DS.color.surface))
        context.stroke(front, with: .color(DS.color.border), lineWidth: 1)

        // 窗口红绿灯：让"这是一个窗口"一眼可读
        for offset in stride(from: 0, to: 3, by: 1) {
            let x = 57 + CGFloat(offset) * 10
            context.fill(
                Path(ellipseIn: CGRect(x: x - 2, y: 38, width: 4, height: 4)),
                with: .color(DS.color.border)
            )
        }

        context.fill(capsule(58, 54, 46, 5), with: .color(DS.color.brand.opacity(0.6)))
        context.fill(capsule(58, 67, 64, 5), with: .color(DS.color.hairline))
        context.fill(capsule(58, 80, 38, 5), with: .color(DS.color.hairline))

        let plusCenter = CGPoint(x: 123, y: 79)
        context.fill(
            Path(ellipseIn: CGRect(x: plusCenter.x - 12, y: plusCenter.y - 12, width: 24, height: 24)),
            with: .color(DS.color.brand)
        )
        var plus = Path()
        plus.move(to: CGPoint(x: plusCenter.x - 5.5, y: plusCenter.y))
        plus.addLine(to: CGPoint(x: plusCenter.x + 5.5, y: plusCenter.y))
        plus.move(to: CGPoint(x: plusCenter.x, y: plusCenter.y - 5.5))
        plus.addLine(to: CGPoint(x: plusCenter.x, y: plusCenter.y + 5.5))
        context.stroke(
            plus,
            with: .color(.white),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
        )
    }

    /// 纸飞机 + 运动弧线 + 虚线地面
    static func response(_ context: inout GraphicsContext) {
        let arcStroke = StrokeStyle(lineWidth: 2, lineCap: .round)
        let arcs: [(CGFloat, CGFloat)] = [(30, 26), (40, 44), (50, 62)]
        for (startX, startY) in arcs {
            var arc = Path()
            arc.move(to: CGPoint(x: startX - 18, y: startY + 6))
            arc.addQuadCurve(
                to: CGPoint(x: startX + 16, y: startY),
                control: CGPoint(x: startX - 2, y: startY - 12)
            )
            context.stroke(arc, with: .color(DS.color.hairline), style: arcStroke)
        }

        var upperWing = Path()
        upperWing.move(to: CGPoint(x: 116, y: 26))
        upperWing.addLine(to: CGPoint(x: 42, y: 54))
        upperWing.addLine(to: CGPoint(x: 78, y: 63))
        upperWing.closeSubpath()
        context.fill(upperWing, with: .color(DS.color.brand))

        var tail = Path()
        tail.move(to: CGPoint(x: 78, y: 63))
        tail.addLine(to: CGPoint(x: 70, y: 88))
        tail.addLine(to: CGPoint(x: 92, y: 66))
        tail.closeSubpath()
        context.fill(tail, with: .color(DS.color.brand.opacity(0.55)))

        var ground = Path()
        ground.move(to: CGPoint(x: 22, y: 94))
        ground.addLine(to: CGPoint(x: 118, y: 94))
        context.stroke(
            ground,
            with: .color(DS.color.hairline),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 6])
        )
    }

    /// 放大镜 + 散点
    static func search(_ context: inout GraphicsContext) {
        let center = CGPoint(x: 58, y: 44)
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50)),
            with: .color(DS.color.brand.opacity(0.42)),
            style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
        )

        var handle = Path()
        handle.move(to: CGPoint(x: 76, y: 62))
        handle.addLine(to: CGPoint(x: 96, y: 82))
        context.stroke(handle, with: .color(DS.color.brand.opacity(0.42)), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        let dots: [(CGFloat, CGFloat, CGFloat)] = [(48, 36, 3.2), (68, 44, 4.2), (52, 58, 3.6)]
        for (x, y, r) in dots {
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(DS.color.textTertiary.opacity(0.55))
            )
        }

        let scattered: [(CGFloat, CGFloat, CGFloat)] = [(114, 28, 3), (124, 52, 2.4), (110, 76, 3.4), (98, 26, 2.2)]
        for (x, y, r) in scattered {
            context.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(DS.color.hairline)
            )
        }
    }

    /// 文件夹 + 内容行 + 加号角标
    static func collection(_ context: inout GraphicsContext) {
        context.fill(roundedRect(30, 22, 36, 20, 6), with: .color(DS.color.field))

        let body = roundedRect(24, 32, 92, 56, 10)
        context.fill(body, with: .color(DS.color.surface))
        context.stroke(body, with: .color(DS.color.border), lineWidth: 1)

        context.fill(capsule(38, 46, 30, 5), with: .color(DS.color.brand.opacity(0.62)))
        context.fill(capsule(38, 58, 58, 5), with: .color(DS.color.hairline))
        context.fill(capsule(38, 70, 44, 5), with: .color(DS.color.hairline))

        let corner = CGPoint(x: 118, y: 80)
        context.fill(
            Path(ellipseIn: CGRect(x: corner.x - 12, y: corner.y - 12, width: 24, height: 24)),
            with: .color(DS.color.brand)
        )
        var plus = Path()
        plus.move(to: CGPoint(x: corner.x - 5.5, y: corner.y))
        plus.addLine(to: CGPoint(x: corner.x + 5.5, y: corner.y))
        plus.move(to: CGPoint(x: corner.x, y: corner.y - 5.5))
        plus.addLine(to: CGPoint(x: corner.x, y: corner.y + 5.5))
        context.stroke(plus, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// 文档 + 虚线空区
    static func body(_ context: inout GraphicsContext) {
        let sheet = roundedRect(40, 16, 64, 76, 9)
        context.fill(sheet, with: .color(DS.color.surface))
        context.stroke(sheet, with: .color(DS.color.border), lineWidth: 1)

        context.fill(capsule(52, 28, 26, 5), with: .color(DS.color.brand.opacity(0.6)))
        context.fill(capsule(52, 40, 40, 5), with: .color(DS.color.hairline))

        let empty = roundedRect(50, 54, 44, 26, 7)
        context.stroke(
            empty,
            with: .color(DS.color.hairline),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 5])
        )

        var slash = Path()
        slash.move(to: CGPoint(x: 56, y: 74))
        slash.addLine(to: CGPoint(x: 88, y: 60))
        context.stroke(
            slash,
            with: .color(DS.color.textTertiary.opacity(0.5)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
    }
}

// MARK: - 空状态

struct EmptyState: View {
    var art: EmptyArt = .tabs
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    /// 紧凑模式：不画插图，只留一行图标 + 文字，用于表格内部的小空区。
    var compact: Bool = false

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var fullBody: some View {
        VStack(spacing: DS.space.lg) {
            EmptyArtView(kind: art, size: CGSize(width: 168, height: 126))

            VStack(spacing: DS.space.xs) {
                Text(title)
                    .font(DS.font.heading)
                    .foregroundStyle(DS.color.textSecondary)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.font.caption)
                        .foregroundStyle(DS.color.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AppButtonStyle(kind: .tinted, size: .small))
            }
        }
        .padding(DS.space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactBody: some View {
        HStack(spacing: DS.space.sm) {
            AppIcon(symbol: "circle.dashed", size: 11, tint: DS.color.textTertiary)
            Text(title)
                .font(DS.font.caption)
                .foregroundStyle(DS.color.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, DS.space.xl)
    }
}
