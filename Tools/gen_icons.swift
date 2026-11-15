//
//  gen_icons.swift
//  生成 Sky CC 的应用图标（AppIcon.iconset → icns）与菜单栏 S 模板图。
//
//  用法：swift Tools/gen_icons.swift <项目根目录>
//  渲染源码 = 用户提供的 ControlCenterSIcon（SwiftUI），
//  通过 NSHostingView 离屏渲染成各尺寸 PNG，再由外部 iconutil 打 icns。
//

import SwiftUI
import AppKit

// ---------------------------------------------------------------------------
// 以下图标源码由用户提供（2026-11-14），除私有 Color(hex:) 改名为 IconHex 外未改动几何
// ---------------------------------------------------------------------------

struct ControlCenterSIcon: View {
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let scale = size / 1024.0

            ZStack {
                // 1. 白色渐变圆角底座
                RoundedRectangle(cornerRadius: 220 * scale, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, IconHex("F2F4F8")],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 220 * scale, style: .continuous)
                            .stroke(IconHex("E5E9F0"), lineWidth: 6 * scale)
                    )

                // 2. S 型斜向连接飘带
                SRibbonShape()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: IconHex("0D47A1"), location: 0.0),
                                .init(color: IconHex("2979FF"), location: 0.35),
                                .init(color: IconHex("64B5F6"), location: 0.75),
                                .init(color: IconHex("B0BEC5"), location: 1.0)
                            ],
                            startPoint: UnitPoint(x: 0.37, y: 0.30),
                            endPoint: UnitPoint(x: 0.62, y: 0.70)
                        )
                    )

                // 3. 上方蓝色开启开关轨道
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [IconHex("2196F3"), IconHex("0A66E8")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.35), lineWidth: 6 * scale)
                            .padding(3 * scale)
                    )
                    .frame(width: 400 * scale, height: 176 * scale)
                    .position(x: 512 * scale, y: 300 * scale)
                    .shadow(color: IconHex("0F172A").opacity(0.14), radius: 16 * scale, y: 14 * scale)

                // 4. 下方浅灰关闭开关轨道
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [IconHex("E2E6EC"), IconHex("ECEFF4")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.8), lineWidth: 6 * scale)
                            .padding(3 * scale)
                    )
                    .frame(width: 400 * scale, height: 176 * scale)
                    .position(x: 512 * scale, y: 724 * scale)
                    .shadow(color: IconHex("0F172A").opacity(0.14), radius: 16 * scale, y: 14 * scale)

                // 5. 上方开启圆钮（右侧）
                SwitchKnobView(scale: scale)
                    .position(x: 624 * scale, y: 300 * scale)

                // 6. 下方关闭圆钮（左侧）
                SwitchKnobView(scale: scale)
                    .position(x: 400 * scale, y: 724 * scale)
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// 立体白色圆形开关钮
private struct SwitchKnobView: View {
    let scale: CGFloat

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.white, IconHex("E6EAF0")],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 4 * scale)
            )
            .frame(width: 136 * scale, height: 136 * scale)
            .shadow(color: IconHex("0F172A").opacity(0.22), radius: 10 * scale, y: 8 * scale)
    }
}

// S 型斜向飘带自定义路径
struct SRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 1024.0
        var path = Path()
        path.move(to: CGPoint(x: 412 * s, y: 212 * s))
        path.addCurve(
            to: CGPoint(x: 495 * s, y: 512 * s),
            control1: CGPoint(x: 300 * s, y: 212 * s),
            control2: CGPoint(x: 290 * s, y: 475 * s)
        )
        path.addCurve(
            to: CGPoint(x: 612 * s, y: 812 * s),
            control1: CGPoint(x: 720 * s, y: 552 * s),
            control2: CGPoint(x: 712 * s, y: 812 * s)
        )
        path.addLine(to: CGPoint(x: 612 * s, y: 636 * s))
        path.addCurve(
            to: CGPoint(x: 512 * s, y: 560 * s),
            control1: CGPoint(x: 655 * s, y: 636 * s),
            control2: CGPoint(x: 650 * s, y: 585 * s)
        )
        path.addCurve(
            to: CGPoint(x: 412 * s, y: 388 * s),
            control1: CGPoint(x: 310 * s, y: 524 * s),
            control2: CGPoint(x: 315 * s, y: 388 * s)
        )
        path.closeSubpath()
        return path
    }
}

// 十六进制颜色辅助扩展（改名避免与工程里的 Color(hex: UInt32) 撞）
private struct HexColor {
    let value: UInt64
    init(_ s: String) {
        let scanner = Scanner(string: s)
        var v: UInt64 = 0
        scanner.scanHexInt64(&v)
        value = v
    }
    var color: Color {
        Color(red: Double((value & 0xFF0000) >> 16) / 255.0,
              green: Double((value & 0x00FF00) >> 8) / 255.0,
              blue: Double(value & 0x0000FF) / 255.0)
    }
}
private func IconHex(_ s: String) -> Color { HexColor(s).color }

// ---------------------------------------------------------------------------
// 离屏渲染
// ---------------------------------------------------------------------------

func renderPNG(_ view: some View, pixel: Int, transparent: Bool) -> Data? {
    let size = CGFloat(pixel)
    let host = NSHostingView(rootView: view.frame(width: size, height: size))
    host.frame = NSRect(x: 0, y: 0, width: size, height: size)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    rep.size = NSSize(width: size, height: size)
    if transparent { rep.forEachPixelBlockSafe() }
    host.cacheDisplay(in: host.bounds, to: rep)
    rep.isOpaque = false
    return rep.representation(using: .png, properties: [:])
}

private extension NSBitmapImageRep {
    // 占位：保留扩展点（当前不需要逐像素处理）
    func forEachPixelBlockSafe() {}
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法：gen_icons.swift <项目根>\n".data(using: .utf8)!)
    exit(1)
}
let root = args[1]
let iconset = root + "/icons/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// 1) 应用图标：iconset 全尺寸
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    guard let png = renderPNG(ControlCenterSIcon(), pixel: s, transparent: false) else {
        FileHandle.standardError.write("渲染失败 \(s)\n".data(using: .utf8)!)
        exit(1)
    }
    let name = (s <= 512) ? "icon_\(s)x\(s).png" : "icon_512x512@2x.png"
    // 32 也作为 16@2x、64 也作为 32@2x、256 也作为 128@2x、512 也作为 256@2x
    try png.write(to: URL(fileURLWithPath: iconset + "/" + name))
}
for base in [16, 32, 128, 256] {
    let doubled = base * 2
    guard let png = renderPNG(ControlCenterSIcon(), pixel: doubled, transparent: false) else { exit(1) }
    try png.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}

// 2) 菜单栏 S 模板图：纯黑 S 飘带 + 透明背景（运行时按模板渲染，跟随菜单栏深浅色）
//    画布 64×64，S 高约 52、居中，四周留呼吸边（状态栏 18pt 视图里约等于 14~15pt 高）
let menuView = SRibbonShape()
    .fill(Color.black)
    .frame(width: 42, height: 52)
    .frame(width: 64, height: 64)
if let png = renderPNG(menuView, pixel: 64, transparent: true) {
    try png.write(to: URL(fileURLWithPath: root + "/icons/MenuSIconTemplate.png"))
    print("已生成 MenuSIconTemplate.png")
} else {
    FileHandle.standardError.write("菜单栏 S 图标渲染失败\n".data(using: .utf8)!)
    exit(1)
}
print("iconset 已生成 → \(iconset)")
