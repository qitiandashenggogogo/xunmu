#!/usr/bin/env swift
// 速寻（MacEverything）App 图标候选生成器 —— 仅用于预览比较，不是定稿品牌。
//
// 用法（在仓库根目录执行）：
//   swift Scripts/generate-icon-proposals.swift
//
// 产物写到 docs/branding/icons/：
//   A-folder-search/  文件夹＋放大镜，蓝青配色
//   B-orbit-search/   光点＋轨迹，蓝紫配色
//   icon-proposals-AB-board.png  A/B 对照板（大图 + 256…16 原尺寸 + 浅/深背景 + 16/32 像素放大）
//
// 全部图形由 CoreGraphics 矢量绘制；每个尺寸都按自己的像素数重新绘制（不是从 1024 缩放），
// 并在 ≤32px 时切到「小尺寸版」：加粗笔画、去掉阴影/高光/光晕等会糊掉的细节。
// 不调用任何 AI 图像生成、不使用外部素材；图标内不含文字。

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 基础工具

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// 透明背景、左上角为原点（y 向下）的位图上下文。
func makeContext(width: Int, height: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// macOS 图标外形：超椭圆（n≈5），比普通圆角矩形的转角更连续。
func squirclePath(_ rect: CGRect, exponent n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width) / 2, b = Double(rect.height) / 2
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let steps = 720
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 给多边形每个角加圆角。
func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let n = points.count
    path.move(to: CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2))
    for i in 1...n {
        path.addArc(tangent1End: points[i % n], tangent2End: points[(i + 1) % n], radius: radius)
    }
    path.closeSubpath()
    return path
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
    CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
}

func fillRadial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ stops: [(CGFloat, CGColor)]) {
    ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 \(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "写入失败 \(url.path)"])
    }
}

// MARK: - 共用：图标底板

/// 设计坐标统一为 1024×1024；图标主体是 824×824 的超椭圆（四周留 100 给投影与系统网格）。
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

struct Detail {
    let pixels: Int
    /// ≤32px：笔画加粗、去掉阴影/高光/光晕。
    var isSmall: Bool { pixels <= 32 }
    /// 设计单位 → 设备像素的比例（阴影参数不受 CTM 影响，需手动换算）。
    var scale: CGFloat { CGFloat(pixels) / 1024 }
}

func drawBody(_ ctx: CGContext, _ d: Detail, fill: (CGContext) -> Void) {
    let shape = squirclePath(body)
    if !d.isSmall {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * d.scale), blur: 24 * d.scale,
                      color: rgb(0x000000, 0.30))
        ctx.addPath(shape)
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    fill(ctx)
    if !d.isSmall {
        // 顶部柔光 + 内描边，给一点材质感；小尺寸不画（会变成一圈脏边）。
        ctx.drawLinearGradient(
            gradient([(0, rgb(0xFFFFFF, 0.22)), (1, rgb(0xFFFFFF, 0))]),
            start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 460), options: []
        )
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
        ctx.setLineWidth(6)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

// MARK: - A：文件夹 + 放大镜（蓝青）

func drawFolderSearch(_ ctx: CGContext, _ d: Detail) {
    drawBody(ctx, d) { ctx in
        ctx.drawLinearGradient(
            gradient([(0, rgb(0x4CD3F8)), (0.55, rgb(0x2A93EA)), (1, rgb(0x1A52CF))]),
            start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: []
        )
    }

    // 文件夹：后片（带标签页）+ 前片。小尺寸整体放大一点，让轮廓占满更多像素。
    let s = d.isSmall
    let fx0: CGFloat = s ? 176 : 196, fx1: CGFloat = s ? 772 : 748
    let tabTop: CGFloat = s ? 226 : 246, backTop: CGFloat = s ? 276 : 290
    let frontTop: CGFloat = s ? 334 : 342, bottom: CGFloat = s ? 716 : 696
    let back = roundedPolygon([
        CGPoint(x: fx0, y: tabTop), CGPoint(x: fx0 + 200, y: tabTop),
        CGPoint(x: fx0 + 244, y: backTop), CGPoint(x: fx1, y: backTop),
        CGPoint(x: fx1, y: bottom), CGPoint(x: fx0, y: bottom),
    ], radius: 36)
    let front = CGPath(roundedRect: CGRect(x: fx0, y: frontTop, width: fx1 - fx0, height: bottom - frontTop),
                       cornerWidth: 36, cornerHeight: 36, transform: nil)

    ctx.saveGState()
    if !s {
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * d.scale), blur: 34 * d.scale,
                      color: rgb(0x08276E, 0.40))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    ctx.addPath(back); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xB4E4FB)), (1, rgb(0x7CC2EE))]),
                           start: CGPoint(x: 0, y: tabTop), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(front); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, rgb(0xFFFFFF)), (1, rgb(0xD6EEFF))]),
                           start: CGPoint(x: 0, y: frontTop), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // 放大镜：压在文件夹右下角，镜框深海军蓝，镜片半透。
    let lens = CGPoint(x: s ? 648 : 640, y: s ? 590 : 580)
    let ringRadius: CGFloat = s ? 150 : 140
    let ringWidth: CGFloat = s ? 66 : 44
    let handleWidth: CGFloat = s ? 92 : 66
    let handleLength: CGFloat = s ? 120 : 135
    let dir = CGPoint(x: cos(CGFloat.pi / 4), y: sin(CGFloat.pi / 4))
    let handleStart = CGPoint(x: lens.x + dir.x * (ringRadius + ringWidth / 2 - 6),
                              y: lens.y + dir.y * (ringRadius + ringWidth / 2 - 6))
    let handleEnd = CGPoint(x: handleStart.x + dir.x * handleLength, y: handleStart.y + dir.y * handleLength)

    ctx.saveGState()
    if !s {
        ctx.setShadow(offset: CGSize(width: 0, height: -16 * d.scale), blur: 30 * d.scale,
                      color: rgb(0x04174A, 0.45))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    // 手柄（圆头粗线）
    ctx.setLineCap(.round)
    ctx.setLineWidth(handleWidth)
    ctx.setStrokeColor(rgb(0x0A2A6E))
    ctx.move(to: handleStart); ctx.addLine(to: handleEnd); ctx.strokePath()
    // 镜框
    ctx.setLineWidth(ringWidth)
    ctx.setStrokeColor(rgb(0x0C3080))
    ctx.strokeEllipse(in: circle(lens, ringRadius))
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    // 镜片：浅青色半透明，压在镜框阴影之上
    ctx.setFillColor(rgb(0xC4F1FF, s ? 0.55 : 0.42))
    ctx.fillEllipse(in: circle(lens, ringRadius - ringWidth / 2 + 1))

    if !s {
        // 镜框内缘亮线 + 镜片高光弧：只在大尺寸给立体感。
        ctx.setLineWidth(6)
        ctx.setStrokeColor(rgb(0x6FB6FF, 0.65))
        ctx.strokeEllipse(in: circle(lens, ringRadius - ringWidth / 2 + 3))
        ctx.setLineCap(.round)
        ctx.setLineWidth(16)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.80))
        ctx.addArc(center: lens, radius: ringRadius - 44, startAngle: .pi * 1.08, endAngle: .pi * 1.42, clockwise: false)
        ctx.strokePath()
        // 手柄高光
        ctx.setLineWidth(10)
        ctx.setStrokeColor(rgb(0x4F8DE8, 0.55))
        let off: CGFloat = 14
        ctx.move(to: CGPoint(x: handleStart.x + off * 0.7, y: handleStart.y - off * 0.7))
        ctx.addLine(to: CGPoint(x: handleEnd.x + off * 0.7 - dir.x * 18, y: handleEnd.y - off * 0.7 - dir.y * 18))
        ctx.strokePath()
    }
}

/// 彗尾：沿圆弧由细到粗、颜色/透明度沿弧渐变的带子，按目标像素尺寸逐像素生成（含 1px 抗锯齿）。
func ribbonImage(pixels: Int, center: CGPoint, radius: CGFloat, tail: CGFloat, sweep: CGFloat,
                 widths: (CGFloat, CGFloat), stops: [(CGFloat, UInt32, CGFloat)]) -> CGImage {
    let scale = CGFloat(pixels) / 1024
    var buffer = [UInt8](repeating: 0, count: pixels * pixels * 4)
    func channel(_ hex: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((hex >> shift) & 0xFF) / 255 }
    for j in 0..<pixels {
        for i in 0..<pixels {
            let x = (CGFloat(i) + 0.5) / scale - center.x
            let y = (CGFloat(j) + 0.5) / scale - center.y   // 设计坐标 y 向下，角度顺时针为正
            var a = atan2(y, x) - tail
            a = a.truncatingRemainder(dividingBy: 2 * .pi)
            if a < 0 { a += 2 * .pi }
            let u = a / sweep
            guard u <= 1 else { continue }
            let half = (widths.0 + (widths.1 - widths.0) * pow(u, 1.15)) / 2
            let dist = abs(hypot(x, y) - radius)
            let coverage = min(max((half - dist) * scale + 0.5, 0), 1)
            guard coverage > 0 else { continue }
            var k = 0
            while k < stops.count - 2 && u > stops[k + 1].0 { k += 1 }
            let (u0, c0, a0) = stops[k], (u1, c1, a1) = stops[k + 1]
            let t = min(max((u - u0) / (u1 - u0), 0), 1)
            let alpha = (a0 + (a1 - a0) * t) * coverage
            let r = channel(c0, 16) + (channel(c1, 16) - channel(c0, 16)) * t
            let g = channel(c0, 8) + (channel(c1, 8) - channel(c0, 8)) * t
            let b = channel(c0, 0) + (channel(c1, 0) - channel(c0, 0)) * t
            let o = (j * pixels + i) * 4
            buffer[o] = UInt8((r * alpha * 255).rounded())
            buffer[o + 1] = UInt8((g * alpha * 255).rounded())
            buffer[o + 2] = UInt8((b * alpha * 255).rounded())
            buffer[o + 3] = UInt8((alpha * 255).rounded())
        }
    }
    let provider = CGDataProvider(data: Data(buffer) as CFData)!
    return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                   space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

// MARK: - B：光点 + 轨迹（蓝紫）

func drawOrbitSearch(_ ctx: CGContext, _ d: Detail) {
    let s = d.isSmall
    let center = CGPoint(x: 512, y: 520)
    let orbitRadius: CGFloat = s ? 268 : 262

    drawBody(ctx, d) { ctx in
        ctx.drawLinearGradient(
            gradient([(0, rgb(0x2C46C4)), (0.5, rgb(0x3A2FB4)), (1, rgb(0x6A27CF))]),
            start: CGPoint(x: 180, y: 120), end: CGPoint(x: 844, y: 904), options: []
        )
        fillRadial(ctx, center: center, radius: 400,
                   [(0, rgb(0x7FA0FF, s ? 0.25 : 0.38)), (1, rgb(0x7FA0FF, 0))])
    }

    if !s {
        // 完整轨道：极淡一圈，只在大尺寸出现。
        ctx.setLineWidth(8)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.13))
        ctx.strokeEllipse(in: circle(center, orbitRadius))
    }

    // 彗尾轨迹：顺时针从 40° 扫到 310°（屏幕坐标 y 向下），宽度由细到粗。
    let head: CGFloat = 310 * .pi / 180
    let sweep: CGFloat = 270 * .pi / 180
    let tail = head - sweep
    let wMin: CGFloat = s ? 16 : 4, wMax: CGFloat = s ? 92 : 64
    // 按像素直接光栅化（极坐标求沿轨迹位置 u 与到轨道中线的距离），
    // 这样颜色/透明度能沿弧线渐变且没有分段拼缝。
    let stops: [(CGFloat, UInt32, CGFloat)] = [
        (0.00, 0x7C63FF, s ? 0.35 : 0.0),
        (0.40, 0x8C7BFF, 0.60),
        (0.80, 0x7FD2FF, 0.95),
        (1.00, 0xEAFBFF, 1.00),
    ]
    let trail = ribbonImage(pixels: d.pixels, center: center, radius: orbitRadius,
                            tail: tail, sweep: sweep, widths: (wMin, wMax), stops: stops)
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(trail, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.restoreGState()

    // 光点：轨迹头 + 中心被找到的点。
    let headPoint = CGPoint(x: center.x + orbitRadius * cos(head), y: center.y + orbitRadius * sin(head))
    if !s {
        fillRadial(ctx, center: headPoint, radius: 150, [(0, rgb(0xA6EBFF, 0.60)), (1, rgb(0xA6EBFF, 0))])
        fillRadial(ctx, center: center, radius: 240, [(0, rgb(0xB4C8FF, 0.55)), (1, rgb(0xB4C8FF, 0))])
    }
    let headRadius: CGFloat = s ? 66 : 50
    ctx.saveGState()
    ctx.addEllipse(in: circle(headPoint, headRadius)); ctx.clip()
    fillRadial(ctx, center: headPoint, radius: headRadius, [(0, rgb(0xFFFFFF)), (0.6, rgb(0xFFFFFF)), (1, rgb(0xC9F3FF))])
    ctx.restoreGState()

    let coreRadius: CGFloat = s ? 96 : 72
    ctx.saveGState()
    ctx.addEllipse(in: circle(center, coreRadius)); ctx.clip()
    fillRadial(ctx, center: CGPoint(x: center.x - coreRadius * 0.25, y: center.y - coreRadius * 0.25),
               radius: coreRadius * 1.3, [(0, rgb(0xFFFFFF)), (0.55, rgb(0xEEF3FF)), (1, rgb(0xB9CCFF))])
    ctx.restoreGState()
}

// MARK: - 渲染与输出

struct Concept {
    let id: String
    let title: String
    let draw: (CGContext, Detail) -> Void
}

let concepts = [
    Concept(id: "A-folder-search", title: "A · 文件夹＋放大镜（蓝青）", draw: drawFolderSearch),
    Concept(id: "B-orbit-search", title: "B · 光点＋轨迹（蓝紫）", draw: drawOrbitSearch),
]

func render(_ concept: Concept, pixels: Int) -> CGImage {
    let ctx = makeContext(width: pixels, height: pixels)
    let d = Detail(pixels: pixels)
    ctx.scaleBy(x: d.scale, y: d.scale)
    concept.draw(ctx, d)
    return ctx.makeImage()!
}

/// 读回某像素的 alpha（左上角原点），用于核查透明边缘。
func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return ctx.data!.assumingMemoryBound(to: UInt8.self)[3]
}

let fm = FileManager.default
let repo = URL(fileURLWithPath: fm.currentDirectoryPath)
guard fm.fileExists(atPath: repo.appendingPathComponent("Scripts/generate-icon-proposals.swift").path) else {
    FileHandle.standardError.write("请在仓库根目录执行：swift Scripts/generate-icon-proposals.swift\n".data(using: .utf8)!)
    exit(1)
}
let outRoot = repo.appendingPathComponent("docs/branding/icons", isDirectory: true)
try fm.createDirectory(at: outRoot, withIntermediateDirectories: true)

let previewSizes = [1024, 512, 256, 128, 64, 32, 16]
var rendered: [String: [Int: CGImage]] = [:]

for concept in concepts {
    let dir = outRoot.appendingPathComponent(concept.id, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [Int: CGImage] = [:]
    for size in previewSizes {
        let image = render(concept, pixels: size)
        images[size] = image
        try writePNG(image, to: dir.appendingPathComponent("\(concept.id)-\(size).png"))
    }
    rendered[concept.id] = images

    // 透明边缘核查：四角必须全透明，主体中心必须不透明。
    let big = images[1024]!
    let corners = [alpha(big, x: 0, y: 0), alpha(big, x: 1023, y: 0), alpha(big, x: 0, y: 1023), alpha(big, x: 1023, y: 1023)]
    let edgeMid = alpha(big, x: 40, y: 512)
    let centerAlpha = alpha(big, x: 512, y: 512)
    print("\(concept.id): 1024 四角 alpha=\(corners) 左侧边缘(40,512) alpha=\(edgeMid) 中心 alpha=\(centerAlpha)")

    // 候选 .icns：iconset 放在临时目录，生成后清理这个临时目录本身。
    let tmp = fm.temporaryDirectory.appendingPathComponent("meicon-\(UUID().uuidString)", isDirectory: true)
    let iconset = tmp.appendingPathComponent("\(concept.id).iconset", isDirectory: true)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (name, size) in [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ] {
        try writePNG(images[size] ?? render(concept, pixels: size), to: iconset.appendingPathComponent("\(name).png"))
    }
    let icns = dir.appendingPathComponent("\(concept.id).icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    do {
        try task.run()
        task.waitUntilExit()
        print("\(concept.id): iconutil 退出码 \(task.terminationStatus) → \(icns.path)")
    } catch {
        print("\(concept.id): iconutil 不可用，跳过 .icns（\(error.localizedDescription)）")
    }
    try? fm.removeItem(at: tmp)
}

// MARK: - A/B 对照板

func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect, nearest: Bool = false) {
    ctx.saveGState()
    ctx.interpolationQuality = nearest ? .none : .high
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
    ctx.restoreGState()
}

func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    (string as NSString).draw(at: point, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
}

func roundedFill(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

let boardWidth = 1860, rowHeight: CGFloat = 660, top: CGFloat = 150
let boardHeight = Int(top + rowHeight * CGFloat(concepts.count) + 30)
let board = makeContext(width: boardWidth, height: boardHeight)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: board, flipped: true)
board.setFillColor(rgb(0xFFFFFF))
board.fill(CGRect(x: 0, y: 0, width: boardWidth, height: boardHeight))
text("速寻 App 图标候选 · A/B 对照（预览，未定稿）", at: CGPoint(x: 48, y: 34), size: 34, weight: .semibold, color: .black)
text("图标内不含文字；全部由 Swift CoreGraphics 代码绘制（Scripts/generate-icon-proposals.swift）。右侧为原像素尺寸；≤32px 使用加粗、去细节的小尺寸版。",
     at: CGPoint(x: 48, y: 90), size: 17, color: NSColor(white: 0.35, alpha: 1))

for (row, concept) in concepts.enumerated() {
    let y0 = top + CGFloat(row) * rowHeight
    let images = rendered[concept.id]!
    text(concept.title + "    \(concept.id)", at: CGPoint(x: 48, y: y0), size: 24, weight: .semibold, color: .black)

    roundedFill(board, CGRect(x: 48, y: y0 + 44, width: 560, height: 560), radius: 28, rgb(0xF2F2F7))
    drawImage(board, images[512]!, in: CGRect(x: 72, y: y0 + 68, width: 512, height: 512))

    for (band, (bg, fg)) in [(rgb(0xF2F2F7), NSColor(white: 0.35, alpha: 1)),
                             (rgb(0x1C1C1E), NSColor(white: 0.75, alpha: 1))].enumerated() {
        let strip = CGRect(x: 640, y: y0 + 44 + CGFloat(band) * 310, width: 1172, height: 300)
        roundedFill(board, strip, radius: 20, bg)
        var x: CGFloat = 664
        for size in [256, 128, 64, 32, 16] {
            let side = CGFloat(size)
            let rect = CGRect(x: x, y: strip.midY - side / 2 - 8, width: side, height: side)
            drawImage(board, images[size]!, in: rect)
            text("\(size)", at: CGPoint(x: x, y: rect.maxY + 4), size: 13, color: fg)
            x += side + 36
        }
        x += 14
        for (size, zoom) in [(16, 6), (32, 3)] {
            let rect = CGRect(x: x, y: strip.midY - 48 - 8, width: 96, height: 96)
            drawImage(board, images[size]!, in: rect, nearest: true)
            text("\(size)px ×\(zoom)", at: CGPoint(x: x, y: rect.maxY + 4), size: 13, color: fg)
            x += 96 + 36
        }
        text(band == 0 ? "浅色背景" : "深色背景", at: CGPoint(x: strip.maxX - 96, y: strip.minY + 14), size: 14, color: fg)
    }
}
NSGraphicsContext.restoreGraphicsState()
let boardURL = outRoot.appendingPathComponent("icon-proposals-AB-board.png")
try writePNG(board.makeImage()!, to: boardURL)
print("对照板 → \(boardURL.path)")
