// ============================================================================
// make_installer_assets.swift —— 生成 pkg 安装器的视觉素材
//
// 产物（写入 templates/installer-assets/）：
//   background.png       Installer 窗口背景 · 浅色（1280×800）
//   background-dark.png  Installer 窗口背景 · 深色（1280×800）
//   welcome.html         「欢迎」页文案
//   conclusion.html      「安装完成」页文案
//
// 用法：swift Tools/make_installer_assets.swift <项目根目录>
//
// 布局实测结论（2026-11-18，macOS 26 Installer）：
//   Installer 自己往背景上叠两块东西——左侧栏（约占宽 30%、高上半段，
//   放介绍/许可/安装等条目，文字色随系统）和文字卡（中间偏右、几乎全高，
//   浅色下是白卡、深色下是深卡，都不透明）。所以背景**不能在左侧画
//   大面积深色板**：侧栏文字压在上面读不清，文字卡还会跟它打架。
//   最终方案：
//   · 全幅淡雅底（浅/深各一套），侧栏与文字卡底下都是低对比度底色
//   · 品牌标（图标 + 字标）放**左下角**——实测两张截图里侧栏条目和
//     文字卡都不占这个角落
// ============================================================================

import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: swift make_installer_assets.swift <项目根目录>")
    exit(1)
}
let root = args[1]
let outDir = root + "/templates/installer-assets"

// ----------------------------------------------------------------------------
// 画布
// ----------------------------------------------------------------------------

let W = 1280.0, H = 800.0

func makeRep() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    return rep
}

func begin(_ rep: NSBitmapImageRep) {
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
}
func end() { NSGraphicsContext.restoreGraphicsState() }

func c(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0, alpha: alpha)
}

// 椭圆径向晕染（必须画进椭圆路径，矩形径向渐变会留方形接缝）
func softWash(_ color: NSColor, center: NSPoint, radius: Double, alpha: CGFloat = 0.09) {
    let inner = color.withAlphaComponent(alpha)
    let outer = color.withAlphaComponent(0.0)
    guard let g = NSGradient(colors: [inner, outer]) else { return }
    let rect = NSRect(x: center.x - radius, y: center.y - radius,
                      width: radius * 2, height: radius * 2)
    g.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: NSPoint(x: 0.5, y: 0.5))
}

// ----------------------------------------------------------------------------
// 1. 背景图（light / dark 两版，几何完全一致，只换配色）
// ----------------------------------------------------------------------------

func drawBackground(dark: Bool) -> NSBitmapImageRep {
    let rep = makeRep()
    begin(rep)

    // 全幅底：上深下浅的极缓渐变
    let baseTop = dark ? c(0x232528, 1) : c(0xE9EEF6, 1)
    let baseBottom = dark ? c(0x17181A, 1) : c(0xFAFBFD, 1)
    if let g = NSGradient(colors: [baseTop, baseBottom]) {
        g.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    }

    // 三团品牌蓝晕（都很淡，压在侧栏/文字卡底下也不影响可读性）
    let blue = dark ? c(0x5B9BF0, 1) : c(0x2979FF, 1)
    let deep = c(0x0D47A1, 1)
    softWash(blue, center: NSPoint(x: W * 0.14, y: H * 0.10), radius: 400,
             alpha: dark ? 0.14 : 0.10)   // 左下（品牌标后面）
    softWash(deep, center: NSPoint(x: W * 0.88, y: H * 0.08), radius: 340,
             alpha: dark ? 0.12 : 0.07)   // 右下角
    softWash(blue, center: NSPoint(x: W * 0.70, y: H * 0.98), radius: 300,
             alpha: dark ? 0.10 : 0.07)   // 右上角

    // —— 品牌标：左下角（侧栏条目与文字卡都不占的区域）——
    let brandX = 56.0

    // 横版组合标（图标在左、Sky CC 字标在右，交付版透明底）+ 柔和投影
    if let combo = NSImage(contentsOfFile: root + "/brand/Brand/Wordmark/logo-combo-horizontal-transparent.png") {
        let w = 300.0
        let h = w * 640.0 / 1644.0
        let rect = NSRect(x: brandX, y: 268, width: w, height: h)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.6 : 0.28)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        combo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSShadow().set()
    }

    let subColor = dark ? NSColor(white: 1, alpha: 0.66) : c(0x5A6B84, 1)

    let sub = NSAttributedString(string: "性能 · 散热 · 灯效 · 驱动", attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: subColor
    ])
    sub.draw(at: NSPoint(x: brandX + 3, y: 216))

    let tagline = NSAttributedString(string: "Intel® NUC 9 Extreme Laptop Kit", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        .foregroundColor: subColor.withAlphaComponent(0.55)
    ])
    tagline.draw(at: NSPoint(x: brandX + 3, y: 192))

    end()
    return rep
}

// ----------------------------------------------------------------------------
// 2. welcome / conclusion（HTML —— 默认文字色随系统外观自适应）
// ----------------------------------------------------------------------------

// 不写死 color：Installer 的 WebView 会按系统深浅模式给默认文字色。
// 只约束字体、行距与层级，交给系统渲染。
func htmlDoc(title: String, paragraphs: [(String, Bool)]) -> String {
    var body = ""
    for (text, isSub) in paragraphs {
        if text.isEmpty {
            body += "<p style=\"margin:14px 0 0 0\"></p>\n"
        } else if isSub {
            body += "<p style=\"margin:4px 0 0 0; font-weight:600\">\(text)</p>\n"
        } else {
            body += "<p style=\"margin:2px 0 0 0\">\(text)</p>\n"
        }
    }
    return """
    <html>
    <head><meta charset="utf-8">
    <style>
        body { font-family: -apple-system, "PingFang SC", sans-serif;
               font-size: 13px; margin: 0; padding: 0; }
        h1   { font-size: 22px; font-weight: 700; margin: 0 0 18px 0; }
    </style></head>
    <body>
    <h1>\(title)</h1>
    \(body)
    </body>
    </html>
    """
}

let welcomeHTML = htmlDoc(title: "欢迎使用「Sky CC」安装器", paragraphs: [
    ("Intel® NUC 9 Extreme Laptop Kit 控制中心", false),
    ("", false),
    ("本安装器将把 Sky CC 安装到「应用程序」文件夹，并配置所需的", false),
    ("后台组件（EC 内核扩展 SkyCCEC.kext、风扇守护进程与 GPU 路由库）。", false),
    ("", false),
    ("升级用户无需先卸载旧版：安装器会自动清理旧版本遗留的内核扩展、", false),
    ("后台守护与登录项，风扇曲线等个人设置会原样保留。", false),
    ("", false),
    ("安装过程需要输入管理员密码。", true),
])

let conclusionHTML = htmlDoc(title: "安装完成", paragraphs: [
    ("Sky CC 已安装到「应用程序」文件夹。", false),
    ("", false),
    ("· 菜单栏右上角会出现 Sky CC 图标，点击即可查看实时监测数据", false),
    ("· 从菜单栏图标打开主窗口，可进行散热、灯效与驱动管理", false),
    ("· 内核扩展将在重启后自动加载（首次安装需要重启一次）", false),
    ("", false),
    ("感谢使用。", true),
])

// ----------------------------------------------------------------------------
// 写盘
// ----------------------------------------------------------------------------

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let bgLight = drawBackground(dark: false)
let bgDark = drawBackground(dark: true)
try! bgLight.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: outDir + "/background.png"))
try! bgDark.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: outDir + "/background-dark.png"))
try! welcomeHTML.write(to: URL(fileURLWithPath: outDir + "/welcome.html"),
                       atomically: true, encoding: .utf8)
try! conclusionHTML.write(to: URL(fileURLWithPath: outDir + "/conclusion.html"),
                          atomically: true, encoding: .utf8)
print("已生成 background.png / background-dark.png / welcome.html / conclusion.html → \(outDir)")
