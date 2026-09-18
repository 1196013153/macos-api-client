#!/usr/bin/env swift
//
// 生成应用图标：Scripts/make-icon.swift
//
// 用 CoreGraphics/AppKit 离屏绘制（圆角渐变底 + {} 符号），产出 .icns。
// 只依赖系统框架，不引入设计资源，保证 clone 下来就能重建图标。
//
// 用法：swift Scripts/make-icon.swift <输出目录>
//
import AppKit
import Foundation

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "Resources",
    isDirectory: true
)

/// 单个尺寸的图标位图。
func renderPNG(size: CGFloat) -> Data? {
    let canvas = NSSize(width: size, height: size)
    let image = NSImage(size: canvas, flipped: false) { rect in
        // 1. 圆角矩形底 + 对角渐变
        let inset = size * 0.055
        let body = NSBezierPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            xRadius: size * 0.225,
            yRadius: size * 0.225
        )
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.24, green: 0.47, blue: 0.96, alpha: 1.0),
            NSColor(srgbRed: 0.42, green: 0.24, blue: 0.86, alpha: 1.0),
        ])
        gradient?.draw(in: body, angle: -70)

        // 2. 顶部高光，让图标更有体积感
        let highlight = NSBezierPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            xRadius: size * 0.225,
            yRadius: size * 0.225
        )
        NSColor.white.withAlphaComponent(0.14).setFill()
        highlight.fill()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        highlight.lineWidth = max(1, size * 0.006)
        highlight.stroke()

        // 3. 中心 {} 符号
        let text = "{ }" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: size * 0.40, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2 + size * 0.012
        )
        text.draw(at: origin, withAttributes: attributes)

        return true
    }

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// .icns 需要的标准尺寸组合
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let data = renderPNG(size: variant.size) else {
        FileHandle.standardError.write(Data("渲染失败：\(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name))
}

let icns = outputDirectory.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 生成 .icns 失败\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("已生成 \(icns.path)")
