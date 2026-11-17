import Foundation

/// `MacConsole` → `SkyCC` 更名迁移（2026-11-17，一次性、幂等）。
///
/// 【为什么需要它】
/// 更名把 bundle id 从 `com.macconsole.console` 换成了 `com.skycc.console`。
/// 在系统看来这是一个**全新的 app**，于是三样东西当场「失联」：
///   1. `UserDefaults` 换了域 —— 菜单栏勾选、皮肤预设、实验开关、窗口记忆全读不到；
///   2. `~/Library/Application Support/MacConsole/` 不再被引用 —— 里面是灯效存档
///      （`rgb_profile.json`）、皮肤副本、风扇曲线、kext 加载器副本、helper 锁；
///   3. 老的 `com.macconsole.helper` 这条 LaunchAgent 还在 launchd 里跑着 ——
///      它和新 helper 会**同时**持有 EC/SMC（两把风扇控制权互相覆盖、灯效被贴回旧值）。
///
/// 这三件事必须在任何业务代码读设置之前收尾，所以挂在
/// `applicationWillFinishLaunching` 的最前面（早于单实例闸门）。
///
/// 【幂等】
/// 做完写一个指纹键 `skycc.migrated.from.macconsole.v1`。之后每次启动只读一个
/// 布尔就返回；用户手动清空设置也不会重跑（旧域已经不在了，各项迁移本身
/// 也都有存在性判断）。
enum SkyCCMigrator {

    /// 旧 bundle id（UserDefaults 域名、以及 pkg 回执里的 component 名）
    private static let legacyBundleID = "com.macconsole.console"
    /// 旧/新数据目录名（`~/Library/Application Support/<name>`）
    private static let legacySupportDir = "MacConsole"
    private static let supportDir = "SkyCC"
    /// 迁移指纹。带 v1 便于将来再改一次目录/域时另开一轮。
    private static let doneKey = "skycc.migrated.from.macconsole.v1"
    /// 旧版用户态守护（都要摘掉，否则与新版抢硬件）
    private static let legacyAgents = [
        "com.macconsole.helper",
        "com.macconsole.autostart",
        "com.macconsole.rgbrestore",
    ]

    private static let logURL: URL = {
        URL(fileURLWithPath: "/tmp/skycc.log")
    }()

    /// 本次启动是否真的做过搬运（主窗口首次出现时据此提示一次）。
    /// 只存在于内存里：提示只在「刚升级那一次」有意义，重启后不再打扰。
    private(set) static var didMigrateThisLaunch = false

    /// 取走「本次启动迁移过」的标记（取一次就清，避免每次开窗都弹提示）。
    static func consumeMigrationNotice() -> Bool {
        guard didMigrateThisLaunch else { return false }
        didMigrateThisLaunch = false
        return true
    }

    /// 入口。只做一次；失败不阻断启动（迁移是「尽量搬过来」，不是硬依赖）。
    static func runIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        log("检测到未迁移的新域，开始从 \(legacyBundleID) 搬家")
        migrateDefaults()
        migrateSupportDirectory()
        purgeLegacyAgents()
        d.set(true, forKey: doneKey)
        didMigrateThisLaunch = true
        log("迁移完成")
    }

    // MARK: - 1) UserDefaults

    /// 把旧域的键逐个搬进当前域。
    ///
    /// 只搬「应用自己的键」：`NS*` 前缀是 AppKit 自动写的窗口/面板记忆（新窗口会
    /// 重新生成，搬过来反而可能带出旧窗口位置的怪尺寸）；其余全搬。
    /// 目标域已有值的不覆盖 —— 万一用户已经在新版里调过，以新版为准。
    private static func migrateDefaults() {
        guard let legacy = UserDefaults(suiteName: legacyBundleID),
              let dict = legacy.persistentDomain(forName: legacyBundleID),
              !dict.isEmpty else {
            log("旧域为空或不存在，跳过设置迁移")
            return
        }
        let std = UserDefaults.standard
        var moved = 0
        for (key, value) in dict where !key.hasPrefix("NS") {
            guard std.object(forKey: key) == nil else { continue }
            std.set(value, forKey: key)
            moved += 1
        }
        std.synchronize()
        log("设置迁移：\(moved) 个键（旧域共 \(dict.count) 个）")
    }

    // MARK: - 2) Application Support 目录

    /// `~/Library/Application Support/MacConsole` → `.../SkyCC`。
    ///
    /// 同卷优先整体 `moveItem`（原子、瞬时）；目标已存在（用户先手动建过、
    /// 或已经跑过一次新版）时退化为「逐项补齐、不覆盖已有文件」。
    private static func migrateSupportDirectory() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return }
        let old = base.appendingPathComponent(legacySupportDir, isDirectory: true)
        let new = base.appendingPathComponent(supportDir, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else {
            log("旧数据目录不存在，跳过目录迁移")
            return
        }
        if !fm.fileExists(atPath: new.path) {
            do {
                try fm.moveItem(at: old, to: new)
                log("数据目录已迁移：\(old.lastPathComponent) → \(new.lastPathComponent)")
            } catch {
                log("数据目录移动失败（\(error.localizedDescription)），尝试逐项复制")
                copyMissing(from: old, to: new, fm: fm)
            }
        } else {
            copyMissing(from: old, to: new, fm: fm)
        }
    }

    /// 逐项补齐：目标已有同名项就跳过，不再递归合并（避免把新版写的内容覆盖掉）。
    private static func copyMissing(from old: URL, to new: URL, fm: FileManager) {
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(at: old,
                                                      includingPropertiesForKeys: nil) else { return }
        var copied = 0
        for src in items {
            let dst = new.appendingPathComponent(src.lastPathComponent)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            if (try? fm.moveItem(at: src, to: dst)) != nil { copied += 1 }
        }
        log("数据目录逐项补齐：\(copied) 项")
    }

    // MARK: - 3) 旧 LaunchAgent

    /// 摘掉 `com.macconsole.*` 三条旧守护。
    ///
    /// 步骤：`bootout`（立刻停）→ `disable`（写进 disabled 数据库，防止残留 plist
    /// 下次登录又被 bootstrap）→ 删 `~/Library/LaunchAgents` 里的 plist。
    /// 注意这里**不能**用 SMAppService 注销 —— 它只能注销「本 bundle 里真实存在
    /// 的 plist」，而新 bundle 里已经没有 com.macconsole.helper.plist 了。
    private static func purgeLegacyAgents() {
        let uid = getuid()
        let fm = FileManager.default
        let laDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

        for label in legacyAgents {
            run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
            run("/bin/launchctl", ["disable", "gui/\(uid)/\(label)"])
            for suffix in [".plist", ".plist.disabled"] {
                let f = laDir.appendingPathComponent(label + suffix)
                if fm.fileExists(atPath: f.path) {
                    try? fm.removeItem(at: f)
                    log("已删除旧登录项 \(label)\(suffix)")
                }
            }
        }
        // 旧 helper 的进程名与新版不同（MacConsoleHelper），plist 删掉后进程可能还活着。
        // 这里不直接 kill：新版 helper 启动时跑的 ensure-agents.sh 会兜这一层
        // （那时新 helper 已经就位，杀掉旧的不会出现「两边都没人管风扇」的空窗）。
    }

    /// 静默跑一个短命令（launchctl），不读输出、失败忽略。
    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - 日志

    /// 追加一行到 /tmp/skycc.log（与 BackendService.diag 同一份，方便排查）。
    private static func log(_ s: String) {
        let line = "[\(Date())] migrate: \(s)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
