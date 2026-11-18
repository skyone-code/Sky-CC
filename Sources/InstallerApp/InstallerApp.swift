//
//  InstallerApp.swift —— 「Sky CC 安装器」自研安装器
//
//  为什么自己写：macOS 自带 Installer（pkg）的窗口布局是死的——侧栏和
//  文字卡直接压在自定义背景图上，没法做出完整的品牌视觉（2026-11-18 实测
//  两张截图都是文字卡盖住品牌面板）。改成自研 app：
//
//    · DMG 里放「Sky CC 安装器.app」（内嵌完整的 Sky CC.app）
//    · 点「开始安装」→ osascript 一次性提权跑 templates/installer-install.sh
//    · 脚本按约定往 /tmp/skycc-install.log 写「STEP n/6 标题」标记，
//      本 app 0.4s 轮询日志驱动进度条
//    · 完成 / 需重启 / 失败三种结果页；失败可直接打开日志
//
//  编译注意：文件名不能叫 main.swift（要用 @main），编译加 -parse-as-library。
//  不复用主程序的 Theme.swift —— 安装器必须自包含，避免把整套 UI 依赖拖进来。
//

import SwiftUI
import AppKit

// ---------------------------------------------------------------- 主题配色
// 与主程序同一套色值（Sources/SkyCC/Theme.swift），但独立实现。

private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        let darkMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let hex = darkMode ? dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                       green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(hex & 0xFF) / 255.0, alpha: 1)
    }))
}

private enum T {
    static let bg = dyn(0xf6f7f9, 0x1e1f21)          // 页面底
    static let card = dyn(0xffffff, 0x26282b)        // 卡片底
    static let txt = dyn(0x3a414b, 0xe8eaef)         // 主文字
    static let dim = dyn(0x626b78, 0xa6aeb9)         // 次文字
    static let line = dyn(0xe0e3e9, 0x3e3f44)        // 描边
    static let blue = dyn(0x2f6fd6, 0x5b9bf0)        // 主色
    static let blueDeep = Color(red: 0x1E/255, green: 0x62/255, blue: 0xD0/255)
    static let green = dyn(0x1f9d55, 0x3cc47a)
    static let red = dyn(0xcf3a3e, 0xef5a5e)
    static let amber = dyn(0xb97a0a, 0xe0a83c)
}

// ---------------------------------------------------------------- 状态机

enum InstallPhase: Equatable {
    case idle
    case installing(stepTitle: String, stepIndex: Int)
    case done(needsReboot: Bool)
    case failed(message: String, cancelled: Bool)
}

// ---------------------------------------------------------------- 主程序

@main
struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var phase: InstallPhase = .idle
    @State private var logTail: String = ""
    @State private var pollTimer: Timer?

    var body: some Scene {
        WindowGroup {
            ContentView(phase: $phase, logTail: $logTail, start: startInstall)
                .frame(width: 640)
                .background(T.bg)
        }
        .windowResizability(.contentSize)
    }

    // ---------------------------------------------------------- 安装流程

    /// idle 与 failed（重试）都可以发起；installing / done 不允许重复点
    private func startInstall() {
        if case .installing = phase { return }
        if case .done = phase { return }

        let script = Bundle.main.resourceURL?
            .appendingPathComponent("install.sh").path
        let embedded = Bundle.main.resourceURL?
            .appendingPathComponent("Sky CC.app").path
        guard let script, FileManager.default.fileExists(atPath: script),
              let embedded, FileManager.default.fileExists(atPath: embedded) else {
            phase = .failed(message: "安装器资源缺失（install.sh 或内嵌主程序）", cancelled: false)
            return
        }

        phase = .installing(stepTitle: "等待管理员授权", stepIndex: 0)
        logTail = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            run.arguments = ["-e",
                "do shell script \"zsh '\(script)'\" with administrator privileges"]
            let errPipe = Pipe()
            run.standardError = errPipe
            run.standardOutput = Pipe()

            do { try run.run() } catch {
                DispatchQueue.main.async {
                    phase = .failed(message: "无法启动提权流程：\(error.localizedDescription)",
                                    cancelled: false)
                }
                return
            }

            // 提权已到手、脚本开跑 —— 立刻开始轮询日志驱动进度条
            DispatchQueue.main.async { startPolling() }
            run.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let rc = run.terminationStatus

            DispatchQueue.main.async {
                stopPolling()
                if rc == 0 {
                    phase = .done(needsReboot: Self.logContains("重启后生效"))
                } else if errText.contains("canceled") || errText.contains("取消") {
                    phase = .failed(message: "已取消管理员授权，未做任何修改。", cancelled: true)
                } else {
                    let tail = Self.logTailText()
                    phase = .failed(
                        message: tail.isEmpty ? "安装失败（退出码 \(rc)）" : tail,
                        cancelled: false)
                }
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            let text = Self.logTailText()
            logTail = text
            if case .installing = phase {
                // 解析日志里最后一个「STEP n/6 标题」
                for line in text.split(separator: "\n").reversed() {
                    if line.contains("STEP "), line.contains("/6 ") {
                        let parts = line.split(separator: " ", maxSplits: 3)
                        if parts.count >= 4, let idx = Int(parts[1]) {
                            phase = .installing(stepTitle: String(parts[3]), stepIndex: idx)
                        }
                        break
                    }
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // ---------------------------------------------------------- 日志工具

    static let logPath = "/tmp/skycc-install.log"

    static func logContains(_ needle: String) -> Bool {
        (try? String(contentsOfFile: logPath, encoding: .utf8))?.contains(needle) ?? false
    }

    static func logTailText() -> String {
        let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n").map(String.init)
        // 只留本次运行（最后一次 ===== 横幅起），不显示历史安装的日志
        if let start = lines.lastIndex(where: { $0.hasPrefix("===== Sky CC 安装") }) {
            lines = Array(lines[start...])
        }
        return lines.suffix(14).joined(separator: "\n")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// ---------------------------------------------------------------- 内容视图

struct ContentView: View {
    @Binding var phase: InstallPhase
    @Binding var logTail: String
    let start: () -> Void

    var body: some View {
        ZStack {
            T.bg.ignoresSafeArea()
            // 高度自适应：不写死 frame 高、不用弹性 Spacer，
            // header / 各阶段内容 / footer 统一 22pt 间距，窗口贴合内容
            VStack(spacing: 22) {
                header
                switch phase {
                case .idle: idleBody
                case .installing(let title, let idx): installingBody(title: title, index: idx)
                case .done(let reboot): doneBody(needsReboot: reboot)
                case .failed(let msg, _): failedBody(msg)
                }
                footer
            }
            .padding(.top, 22)
            .padding(.bottom, 4)
        }
    }

    // 头部：竖版组合标（图标在上、Sky CC 字标在下）+ 标题/副标题（2026-11-18 定稿）
    private var header: some View {
        HStack(spacing: 18) {
            if let combo = Self.logoCombo {
                Image(nsImage: combo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 86)
            } else {
                iconImage
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Sky CC 安装器")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(T.txt)
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(T.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // 顶部留白由外层 VStack 统一 22pt，这里不再叠加
    }

    /// 副标题：版本 + 机型全称（Intel ARK 官方命名，2026-11-18 用户定稿）
    private var subtitle: String {
        var parts: [String] = []
        if let v = Self.embeddedVersion { parts.append("版本 \(v)") }
        parts.append("Intel® NUC 9 Extreme Laptop Kit")
        return parts.joined(separator: " · ")
    }

    /// 竖版组合标（构建时拷到 Resources/LogoComboVertical.png）
    /// 2026-11-18：多级减半预缩放（安装器是独立 target，拿不到 BrandAssets，就地实现）
    static var logoCombo: NSImage? {
        guard let url = Bundle.main.url(forResource: "LogoComboVertical",
                                        withExtension: "png"),
              let src = NSImage(contentsOf: url),
              let tiff = src.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        var img = src
        var h = rep.pixelsHigh
        while h > 344 {   // 86pt @2x = 172；逼近到 2× 内再末级重采样
            img = Self.renderHalf(img, width: rep.pixelsWide / 2, height: h / 2)
            h /= 2
        }
        return Self.renderHalf(img, width: rep.pixelsWide * 172 / rep.pixelsHigh, height: 172)
    }

    /// 高质量重采样（带 alpha），锯齿修复用的最小实现
    private static func renderHalf(_ img: NSImage, width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: max(1, width), pixelsHigh: max(1, height),
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(origin: .zero, size: rep.size),
                 from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }

    /// 内嵌 Sky CC.app 的 CFBundleShortVersionString（构建时打进 Resources）
    static var embeddedVersion: String? {
        guard let plist = Bundle.main.resourceURL?
            .appendingPathComponent("Sky CC.app/Contents/Info.plist"),
              let dict = NSDictionary(contentsOfFile: plist.path) as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    /// 构建时注入的更新说明（CHANGELOG 最新一节，ReleaseNotes.txt）
    static var releaseNotes: String? {
        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var iconImage: Image {
        if let icon = Bundle.main.image(forResource: "AppIcon") {
            return Image(nsImage: icon)
        }
        return Image(systemName: "arrow.down.circle.fill")
    }

    // 首页：要点列表 + 更新说明 + 安装按钮（模块间距统一 22pt）
    private var idleBody: some View {
        VStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                bullet("安装到「应用程序」文件夹，含后台组件与 GPU 路由库")
                bullet("自动清理旧版本遗留的内核扩展、守护与登录项，无需先卸载")
                bullet("个人设置（风扇曲线 / 灯效档）原样保留")
                bullet("安装过程需要输入一次管理员密码")
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.line, lineWidth: 1))
            .padding(.horizontal, 44)

            // 更新说明（构建时从 CHANGELOG 最新一节注入；没有就不显示）
            if let notes = Self.releaseNotes {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(T.blue)
                        Text("本次更新")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(T.txt)
                    }
                    ScrollView {
                        Text(notes)
                            .font(.system(size: 12))
                            .foregroundStyle(T.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    // 固定高度：保证窗口高度可计算（内容超出则内部滚动）
                    .frame(height: 118)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(T.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(T.line, lineWidth: 1))
                .padding(.horizontal, 44)
            }

            Button {
                start()
            } label: {
                Text("开始安装")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 220, height: 42)
                    .background(
                        LinearGradient(colors: [T.blueDeep, T.blue],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(T.blue)
                .font(.system(size: 14))
            Text(text).font(.system(size: 13.5)).foregroundStyle(T.txt)
        }
    }

    // 安装中：进度条 + 步骤名 + 日志尾部
    private func installingBody(title: String, index: Int) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(max(index, 0)), total: 6)
                .progressViewStyle(.linear)
                .tint(T.blue)
                .padding(.horizontal, 44)
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2.fill").foregroundStyle(T.blue)
                Text(index > 0 ? "(\(index)/6) \(title)" : title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(T.txt)
                Spacer()
            }
            .padding(.horizontal, 44)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(logTail.isEmpty ? "正在等待管理员授权…" : logTail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(T.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logEnd")
                }
                .frame(height: 140)
                .padding(12)
                .background(T.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.line, lineWidth: 1))
                .padding(.horizontal, 44)
                .onChange(of: logTail) { _, _ in
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
        }
    }

    // 完成页
    private func doneBody(needsReboot: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: needsReboot ? "arrow.triangle.2.circlepath.circle.fill"
                                          : "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(needsReboot ? T.amber : T.green)
            Text(needsReboot ? "安装完成，需要重启一次" : "安装完成")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(T.txt)
            Text(needsReboot
                 ? "内核扩展已装入系统。macOS 不支持热加载，重启后自动生效\n（风扇控制与 CPU 实时频率在重启后可用）。"
                 : "Sky CC 已就绪，马上为你打开。")
                .font(.system(size: 13))
                .foregroundStyle(T.dim)
                .multilineTextAlignment(.center)
            Button("打开 Sky CC") { Self.openInstalledApp() }
                .buttonStyle(.borderedProminent)
                .tint(T.blue)
        }
        .onAppear {
            if !needsReboot {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    Self.openInstalledApp()
                }
            }
        }
    }

    // 失败页
    private func failedBody(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(T.red)
            Text("安装未完成")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(T.txt)
            Text(msg)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(T.dim)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .padding(.horizontal, 40)
            HStack(spacing: 12) {
                Button("查看日志") { Self.openLog() }
                    .buttonStyle(.bordered)
                Button("重试") { start() }
                    .buttonStyle(.borderedProminent)
                    .tint(T.blue)
            }
        }
    }

    // 底部：版权与开源声明
    private var footer: some View {
        VStack(spacing: 4) {
            Text("Sky CC · 仅限配套机型使用")
            Text("内核扩展 SkyCCEC.kext 协议基于 TongfangEnhancer（GPL-2.0）实现，源码随附")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(T.dim.opacity(0.75))
        .multilineTextAlignment(.center)
        // 外层 .padding(.bottom, 4) + 这里的 18 = 22，与模块间距同节奏
        .padding(.bottom, 18)
    }

    static func openInstalledApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/Sky CC.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    static func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: InstallerApp.logPath))
    }
}
