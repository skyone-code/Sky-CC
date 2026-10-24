import SwiftUI
import AppKit

/// 开发用离屏渲染：`Mac控制台 --ui-shots <目录>` → 把各页渲染成 PNG 后退出。
///
/// 为什么需要：本机是双 GPU 镜像 + 多 Space 环境，`screencapture` 抓不到
/// 落在别的 Space 上的窗口；ImageRenderer 直接把 SwiftUI 视图树画进位图，
/// 不依赖窗口服务器，改版式时能立刻看到结果。
///
/// 只在显式带参数时触发，正常启动完全不受影响。
@MainActor
enum UIShot {

    static func handleIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui-shots"), i + 1 < args.count else { return false }
        let dir = args[i + 1]
        Task { @MainActor in
            await BackendService.shared.start()
            await BackendService.shared.checkKext()
            MonitorStore.shared.attach(BackendService.shared)
            // 等第一帧快照（最多 ~6 秒），否则卡片全是空数据
            for _ in 0..<15 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if MonitorStore.shared.connected { break }
            }
            render(dir)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func render(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let backend = BackendService.shared
        let store = MonitorStore.shared

        func page<V: View>(_ v: V) -> some View {
            v.environmentObject(backend)
                .environmentObject(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
        }

        let items: [(String, AnyView)] = [
            ("01-概览", AnyView(page(OverviewView()))),
            ("02-性能", AnyView(page(MonitorView()))),
            ("03-控制", AnyView(page(ControlView()))),
            ("04-灯效", AnyView(page(RGBView()))),
            ("05-实验性", AnyView(page(ExperimentalView()))),
            ("06-设置", AnyView(page(MiscView()))),
        ]

        for (name, view) in items {
            // 2.8.6：改成主窗口的真实尺寸（1180×760）再留一点余量 ——
            // 之前用 2100 高渲染，卡片会被撑成一整屏，看不出真实窗口里「有没有留空」。
            guard let img = snapshot(view, size: CGSize(width: 1180, height: 800)),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("渲染失败：\(name)\n".utf8))
                continue
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("已渲染 \(url.path)")
        }
    }

    /// 用 NSHostingView + cacheDisplay 离屏出图。
    ///
    /// 为什么不用 ImageRenderer：它不给 ScrollView 做布局，出来的是一张纯底色
    /// （2.7.0 第一次尝试就是这么踩空的）。NSHostingView 配一个 borderless 窗口
    /// 能走完整的 AppKit 布局与绘制流程，ScrollView 也照常渲染。
    private static func snapshot<V: View>(_ v: V, size: CGSize) -> NSImage? {
        let host = NSHostingView(rootView: v)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        win.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        win.orderOut(nil)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
}
