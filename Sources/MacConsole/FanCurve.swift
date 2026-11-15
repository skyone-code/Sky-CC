import Foundation

// MARK: - 曲线数据模型

/// 单个控制点：温度（°C）→ 风扇档位（0-7）。
struct FanCurvePoint: Codable, Identifiable, Equatable {
    var id: UUID
    var temp: Int   // °C（30-100）
    var level: Int  // 0-7
    init(id: UUID = UUID(), temp: Int, level: Int) {
        self.id = id
        self.temp = temp
        self.level = level
    }
}

/// 整条风扇曲线配置（可序列化，落盘恢复）。
struct FanCurveConfig: Codable {
    var source: String = "max"      // cpu / gpu / max（取 CPU/GPU 较高值）
    var failsafeTemp: Int = 95      // ≥ 此温度强制全速（绕过曲线）
    var points: [FanCurvePoint]     // 按 temp 升序

    static let tempMin = 30
    static let tempMax = 100
    static let levelMax = 7

    static var `default`: FanCurveConfig {
        FanCurveConfig(source: "max", failsafeTemp: 95, points: [
            FanCurvePoint(temp: 40, level: 0),
            FanCurvePoint(temp: 55, level: 2),
            FanCurvePoint(temp: 70, level: 4),
            FanCurvePoint(temp: 85, level: 6),
            FanCurvePoint(temp: 95, level: 7),
        ])
    }

    var sortedPoints: [FanCurvePoint] { points.sorted { $0.temp < $1.temp } }

    /// 给定温度，按分段线性插值算目标档位（钳到 0-7）。
    func level(for temp: Int) -> Int {
        let pts = sortedPoints
        guard !pts.isEmpty else { return 0 }
        if temp <= pts.first!.temp { return clamp(pts.first!.level) }
        if temp >= pts.last!.temp { return clamp(pts.last!.level) }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if temp >= a.temp && temp <= b.temp {
                let span = Double(b.temp - a.temp)
                let frac = span == 0 ? 0 : Double(temp - a.temp) / span
                let lv = Double(a.level) + frac * Double(b.level - a.level)
                return clamp(Int((lv + (lv >= 0 ? 0.5 : -0.5)).rounded()))
            }
        }
        return clamp(pts.last!.level)
    }

    private func clamp(_ l: Int) -> Int { min(FanCurveConfig.levelMax, max(0, l)) }
}

// MARK: - 持久化（重启后曲线随模式恢复）

enum FanCurveStore {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacConsole", isDirectory: true)
            .appendingPathComponent("fan_curve.json")
    }

    static func load() -> FanCurveConfig? {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(FanCurveConfig.self, from: data) else { return nil }
        return cfg
    }

    @discardableResult
    static func save(_ cfg: FanCurveConfig) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cfg) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

// MARK: - 控制环（进程内常驻，随服务启动；服务随 app 启动即激活）

/// 软件风扇曲线控制环：每 2s 读温度 → 按曲线插值算档位 → 调 EC 写 FAN_CTRL。
/// 仅在目标档位变化且距上次写 ≥ 2.5s 时才写 EC，避免抖动。
/// 高温（≥ failsafeTemp）直接交 EC 自动+BOOST，绕过曲线作为保护。
final class FanCurveController: ObservableObject {
    static let shared = FanCurveController()

    @Published var config: FanCurveConfig = FanCurveStore.load() ?? .default
    @Published var active: Bool = false
    @Published var currentTemp: Int = 0
    @Published var currentLevel: Int = 0

    private var loop: Task<Void, Never>?
    private var appliedLevel: Int = -1
    private var lastWrite = Date.distantPast
    private let minDwell: TimeInterval = 2.5

    /// 2.7.6：控制环与「退出曲线模式」之间的竞态闸门。
    ///
    /// 以前 stop() 只是 cancel + 把 loop 置 nil，但 tick() 可能正跑到一半：
    /// 它算完目标档位后调 fc.setLevel()，这一步会**重新断言接管标志**并把
    /// FAN_CTRL 写回 0x80|档位——如果它恰好落在 setMode("normal") 之后，
    /// 0x751 就被写回手动档了，界面表现为「从曲线切不回自动」。
    /// 用户当时靠「先点手动再点自动」绕过去，正是因为第二次 stop() 之后没有
    /// 在途 tick 了。
    ///
    /// 修法：所有 EC 写都放进这条串行队列，stop() 用 queue.sync 做一次栅栏，
    /// 保证它返回之后不可能再有 tick 的写落地。
    private let writeGate = DispatchQueue(label: "com.macconsole.fancurve.write")
    private var running = false

    func start() {
        guard loop == nil else { return }
        writeGate.sync { self.running = true }
        DispatchQueue.main.async { self.active = true }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        // 栅栏：等在途 tick 的写事务收尾，之后 running=false 才生效
        writeGate.sync { self.running = false }
        // 曲线运行期间每一笔 setLevel() 都会断言 0x741 bit0（AP exist / 控制中心接管）。
        // 2.8.14（用户要求）：**退出曲线必须把 0x751 交还**，否则界面一直显示「自定义档」，
        // 控制页的散热档 / 功耗档点了没反应。
        // 交还走安全顺序（先放档位 0x751←0x00，再确认接管标志在位），不触发 FAN_ABNORMAL。
        let doorHeld = appliedLevel >= 0   // 99 = 高温兜底的 boost，同样算「我们改过档位」
        appliedLevel = -1
        DispatchQueue.main.async { self.active = false }
        if doorHeld {
            let r = FanControl.shared.releaseManualDoor()
            if r?.ok != true {
                NSLog("[FanCurve] 交还风扇档位失败 status=%d（不影响曲线已停）", r?.status ?? -99)
            }
        }
    }

    /// 配置读取统一走主线程（UI 也在主线程写），避免结构体撕裂读。
    private func tick() {
        guard FanControl.kextLoaded() else { return }
        // 2.8.15：温度走 SMC / NVAccel（NativeAPI.fanStatusCached），
        // 曲线环**不再读 EC** —— 温度不来自 EC，转速只取缓存。
        let st = NativeAPI.fanStatusCached()
        let cfg = DispatchQueue.main.sync { self.config }
        // 返回的数值是 UInt8/Int 等具体类型，装箱进 Any 后不能用 as? Int
        // 直接取（UInt8 不是 Int 的子类，会失败变成 0）；统一走 NSNumber 桥接最稳。
        let tc = (st["temp_cpu"] as? NSNumber)?.intValue ?? 0
        let tg = (st["temp_gpu"] as? NSNumber)?.intValue ?? 0
        let temp: Int
        switch cfg.source {
        case "cpu": temp = tc
        case "gpu": temp = tg
        default: temp = max(tc, tg)
        }

        let fc = FanControl.shared
        if temp >= cfg.failsafeTemp {
            // 写事务必须过闸门：stop() 之后绝不能再碰 EC
            writeGate.sync {
                guard self.running, self.appliedLevel != 99 else { return }
                _ = fc.setMode("boost")
                self.appliedLevel = 99
                self.lastWrite = Date()
            }
            DispatchQueue.main.async { [weak self] in
                self?.currentTemp = temp
                self?.currentLevel = 7
            }
            return
        }

        let target = cfg.level(for: temp)
        writeGate.sync {
            guard self.running else { return }
            let now = Date()
            if target != self.appliedLevel && now.timeIntervalSince(self.lastWrite) >= self.minDwell {
                _ = fc.setLevel(target)
                self.appliedLevel = target
                self.lastWrite = now
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.currentTemp = temp
            self?.currentLevel = target
        }
    }

    /// 供 /api/fan GET 与 UI 使用：曲线当前状态快照。
    func snapshot() -> [String: Any] {
        [
            "active": active,
            "source": config.source,
            "failsafe_temp": config.failsafeTemp,
            "current_temp": currentTemp,
            "current_level": currentLevel,
            "points": config.points.map { ["temp": $0.temp, "level": $0.level] },
        ]
    }
}
