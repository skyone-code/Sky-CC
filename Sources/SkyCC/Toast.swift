import SwiftUI

/// 全局操作提示：任何页面 post 一句话，窗口底部弹一个胶囊，2.2 秒自动消失。
///
/// 为什么做成单例而不是各页面自己 @State：
/// 控制页、灯效页、设置页都要弹，之前三个页面各写了一份 toast 状态 + overlay +
/// 定时器，改文案要改三处。统一到这里之后，任何地方 `ToastCenter.shared.show(…)`
/// 即可，overlay 由 `.toastOverlay()` 挂一次。
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var text: String?

    private var seq = 0
    private let lock = NSLock()

    /// 弹一条提示。新提示会顶掉旧的（序号比对，避免旧定时器把新提示清掉）
    func show(_ s: String) {
        DispatchQueue.main.async {
            self.lock.lock(); self.seq += 1; let mine = self.seq; self.lock.unlock()
            self.text = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self.lock.lock(); let cur = self.seq; self.lock.unlock()
                if cur == mine { self.text = nil }
            }
        }
    }

    /// 开关类操作的统一文案：「已打开 · 触控板」/「已关闭 · 触控板」
    func showSwitch(_ name: String, _ on: Bool) {
        show(on ? "已打开 · \(name)" : "已关闭 · \(name)")
    }
}

private struct ToastOverlay: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let t = center.text {
                    HStack(spacing: 7) {
                        Image(systemName: icon(for: t)).font(.system(size: 11.5, weight: .semibold))
                        Text(t).font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.78), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
                }
            }
            .animation(.easeOut(duration: 0.2), value: center.text)
    }

    private func icon(for t: String) -> String {
        if t.hasPrefix("已关闭") { return "slash.circle.fill" }
        if t.hasPrefix("已打开") { return "checkmark.circle.fill" }
        if t.hasPrefix("失败") || t.contains("失败") { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }
}

extension View {
    /// 在窗口底部挂上全局提示层（每个页面挂一次即可）
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}
