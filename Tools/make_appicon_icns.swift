// ============================================================================
// make_appicon_icns.swift —— AppIcon 生成 v3（2026-11-18 用户定稿）
//
// 用户明确：brand/Brand/Icon-roundrect-transparent.png **本身就是完整主图标**——
// 自带圆角矩形 + 透明四角，就是最终形态。不做抠图、不合成底、不二次蒙版，
// 只做「等比缩放进 1024 画布居中」+ iconset → iconutil。
//
// （v2 的教训：把主体抠出来再合成到自画 squircle 上，构图被改了，不对；
//   v1 的教训：把卡片缩进 824/1024 留透明边距，系统容器再垫一层圆角底，
//   Dock 里就成了「圆角套圆角」。满幅直出才符合用户预期。）
//
// 用法：swift Tools/make_appicon_icns.swift <项目根目录>
// 产物：icons/AppIcon.icns（旧文件备份 /tmp/AppIcon.icns.bak）
//       /tmp/AppIcon-1024-masked.png（1024 母版）/ /tmp/AppIcon-preview.png（256px）
// ============================================================================

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: swift make_appicon_icns.swift <项目根目录>")
    exit(1)
}
let root = args[1]
let masterPath = root + "/brand/Brand/Icon-roundrect-transparent.png"
let outDir = root + "/icons"

guard let master = NSImage(contentsOfFile: masterPath) else {
    print("错误：读不到母版 \(masterPath)")
    exit(1)
}
let W = master.size.width, H = master.size.height
print("母版 \(W)×\(H)")

// —— 超采样补抗锯齿（2026-11-18）——
// 实测母版边缘过渡像素占比 0%：整个图形（含圆角、S 主体）都是硬像素，
// 直接缩进 1024 后 Dock/菜单栏里白卡边缘是阶梯。放大到 2048 再减半回 1024，
// 2× 面积平均让边缘产生真实过渡像素 —— 构图、圆角、透明四角完全不变。
func renderTo(_ img: NSImage, size: NSSize) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    img.draw(in: NSRect(origin: .zero, size: size),
             from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: size)
    out.addRepresentation(rep)
    return out
}

// 等比缩放进 1024×1024 画布，居中（长边贴边，不裁切、不加边距）
let canvas: CGFloat = 1024
let scale = min(canvas / W, canvas / H)
let dw = W * scale, dh = H * scale
let offX = (canvas - dw) / 2, offY = (canvas - dh) / 2
print("缩放 ×\(scale) → \(dw)×\(dh)，居中")

// 先铺 2048 超采样画布，再减半到 1024
let up = renderTo(master, size: NSSize(width: dw * 2, height: dh * 2))
let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocusFlipped(false)
NSGraphicsContext.current!.imageInterpolation = .high
up.draw(in: NSRect(x: 0, y: 0, width: dw, height: dh),
        from: .zero, operation: .sourceOver, fraction: 1)
out.unlockFocus()

// 写 1024 母版 PNG（透明角保留）
guard let t2 = out.tiffRepresentation,
      let r2 = NSBitmapImageRep(data: t2),
      let png = r2.representation(using: .png, properties: [:]) else {
    print("错误：输出编码失败"); exit(1)
}
let tmp1024 = "/tmp/AppIcon-1024-masked.png"
try! png.write(to: URL(fileURLWithPath: tmp1024))
print("已写 \(tmp1024)")

// iconset（sips 缩放保 alpha）→ iconutil 出 icns
let iconset = "/tmp/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(px)", "\(px)", tmp1024, "--out", "\(iconset)/\(name)"]
    try! task.run(); task.waitUntilExit()
}

let bak = "/tmp/AppIcon.icns.bak"
let icns = "\(outDir)/AppIcon.icns"
if FileManager.default.fileExists(atPath: icns) {
    try? FileManager.default.removeItem(atPath: bak)
    try! FileManager.default.copyItem(atPath: icns, toPath: bak)
    print("旧 icns 已备份 → \(bak)")
}
let util = Process()
util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
util.arguments = ["-c", "icns", iconset, "-o", icns]
try! util.run(); util.waitUntilExit()
print("已生成 \(icns)")

// 256px 预览
let pv = Process()
pv.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
pv.arguments = ["-z", "256", "256", tmp1024, "--out", "/tmp/AppIcon-preview.png"]
try! pv.run(); pv.waitUntilExit()
print("预览 → /tmp/AppIcon-preview.png")
