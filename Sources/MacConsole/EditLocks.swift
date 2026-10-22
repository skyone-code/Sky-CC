import Foundation

/// 交互锁：用户刚操作过的控件，在锁定期内不被轮询回读覆盖。
/// 背景：硬件状态每 1s 回读一次，写入 EC 后回读可能有几秒延迟，
/// 不架锁就会出现「用户点了选项，下一秒被刷回旧值」的观感（bug：点完跳回去）。
@MainActor
final class EditLocks: ObservableObject {
    private var until: [String: Date] = [:]

    func locked(_ key: String) -> Bool {
        (until[key] ?? .distantPast) > Date()
    }

    /// 锁 key 指定的控件 sec 秒（默认 2.6s，覆盖两个轮询周期）
    func lock(_ key: String, _ sec: Double = 2.6) {
        until[key] = Date().addingTimeInterval(sec)
    }
}
