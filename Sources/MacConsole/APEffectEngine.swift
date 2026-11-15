import Foundation
import Combine

/// 原厂三个「AP 软件动画」——霓虹 / 堆叠 / 冲击。
///
/// 【为什么要自己算帧】
/// 本机 ITE 8291 的 `0x08` 固件通道**没有** 12/13/15 号效果（文档 §2.1 坑表 + §6）。
/// 原厂 `DefaultRGBKB.exe` 里这三个走的是 `Set_ITE_Effect_Type_ApMode` →
/// `AP_Effect_Task` 线程：上位机逐帧算出 126 个灯位的颜色，再用逐键通道
/// （`Set_ITE_Effect_Type_UserMode`）推给芯片。以前我们把 0x0C/0x0D/0x0F
/// 当固件码发下去，固件不认识 → 三个效果「点了都没反应 / 看起来一样」。
///
/// 【算法出处】
/// 反编译 `LightingModel.LM_ITE_RGB::AP_Effect_Task`（rid 136）逐条还原：
///   · 霓虹 `effect=15`：`Thread.Sleep(50 * speed)`；帧号 0..6 循环（`if frame==7 frame=0`），
///     每帧取调色板第 frame 个颜色，整屏单色（`Set_ITE_Effect_Type_StaticMode`）。
///   · 冲击 `effect=13`：`Sleep(20 * speed)`；20 帧循环。
///     frame<10 时点亮 **列 frame、frame+1**（palette[0]）+ **列 20-frame、19-frame**（palette[1]）；
///     frame≥10 时 g=frame-10，点亮 **列 10-g、9-g**（palette[2]）——两侧向中心收拢，再从中心往左扫。
///   · 堆叠 `effect=12`：`Sleep(20 * speed)`；45 帧循环（15 组灯位 × 3 色）。
///     每帧清屏 → 中心灯 52 常亮 → 点亮该帧的对称索引组，颜色 = palette[(frame/15)%3]。
///
/// 索引制：`index = col + row_phys * 21`，`row_phys 0 = 键盘最下面一排`（与
/// `setMatrixRows` 里 `srcRow = numRows - 1 - chipRow` 的翻转方向一致）。
/// speed 用固件语义：**1 = 最快、10 = 最慢**（原厂 `Translate_ITE_SpeedValue` 同理）。
final class APEffectEngine: ObservableObject {
    static let shared = APEffectEngine()

    @Published private(set) var running = false
    /// 正在跑的效果 key（空串 = 没跑）
    @Published private(set) var style: String = ""
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.macconsole.apeffect", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frame = 0
    private var effect: KeyboardEffect = .neon
    private var speed = 5
    private var bright = 75
    private var palette: [[Int]] = []
    /// 上一帧还没发完就跳过这一帧：芯片 6 行要 ~6ms，XPC 往返再占几毫秒，
    /// 堆到队列里只会让画面越来越滞后。
    private var inFlight = false

    private let rows = 6
    private let cols = 21

    // MARK: - 堆叠：原厂 AP_Effect_Task 的 15 组索引（已去重，R/G/B 三通道重复项合并）
    //
    // 每组都是关于中心（索引 52 = col 10 / row_phys 2）对称的「层」，
    // 逐帧向中心收拢；15 帧走完一层颜色，45 帧三色循环。
    private static let stackFrames: [[Int]] = [
        [105, 20, 125],
        [21, 84, 106, 19, 41, 104, 124],
        [21, 22, 63, 84, 85, 107, 18, 40, 41, 83, 103, 104, 123],
        [22, 23, 42, 63, 64, 85, 86, 108, 17, 38, 39, 62, 82, 83, 102, 103, 122],
        [23, 24, 42, 43, 64, 65, 86, 87, 109, 16, 37, 38, 61, 62, 81, 82, 101, 102, 121],
        [24, 25, 43, 44, 65, 66, 87, 88, 110, 15, 36, 37, 60, 61, 80, 81, 100, 101, 120],
        [25, 26, 44, 45, 66, 67, 88, 89, 111, 14, 35, 36, 59, 60, 79, 80, 99, 100, 119],
        [26, 27, 45, 46, 67, 68, 89, 90, 112, 13, 34, 35, 58, 59, 78, 79, 98, 99, 118],
        [27, 28, 46, 47, 68, 69, 90, 91, 113, 12, 33, 34, 57, 58, 77, 78, 97, 98, 117],
        [9, 28, 29, 47, 48, 69, 70, 91, 92, 114, 11, 32, 33, 56, 57, 76, 77, 96, 97, 116],
        [10, 29, 30, 48, 49, 70, 71, 92, 93, 31, 32, 55, 56, 75, 76, 95, 96],
        [30, 49, 50, 71, 72, 93, 31, 54, 55, 74, 75, 94],
        [50, 51, 72, 53, 54, 73],
        [51, 52, 53],
        [52],
    ]

    var isRunning: Bool { running }

    // MARK: - 起停

    /// 启动动画。`palette` 至少 1 色；霓虹用前 7 色、堆叠/冲击用前 3 色。
    @discardableResult
    func start(_ e: KeyboardEffect,
               speed: Int,
               palette: [[Int]],
               brightness: Int) -> Bool {
        guard e.isSoftwareAnimation else {
            lastError = "\(e.title) 不是软件动画"
            return false
        }
        stop()
        effect = e
        self.speed = max(1, min(10, speed))
        bright = max(0, min(100, brightness))
        self.palette = palette.isEmpty ? [[255, 0, 0]] : palette
        frame = 0
        inFlight = false
        lastError = nil

        let period = framePeriodMs(effect, speed: self.speed)
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 首帧立刻出，别让用户等一个周期
        t.schedule(deadline: .now(), repeating: .milliseconds(period), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()

        DispatchQueue.main.async {
            self.running = true
            self.style = KeyboardCatalog.key(for: e)
        }
        return true
    }

    func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async {
            self.running = false
            self.style = ""
        }
    }

    /// 原厂 `Thread.Sleep` 的周期（毫秒）
    private func framePeriodMs(_ e: KeyboardEffect, speed: Int) -> Int {
        switch e {
        case .neon:            return 50 * speed   // AP_Effect_Task: Sleep(50*speed)
        case .stack, .impact:  return 20 * speed   // Sleep(20*speed)
        default:               return 100
        }
    }

    // MARK: - 帧循环

    private func tick() {
        guard !inFlight else { return }
        let f = frame
        let total = totalFrames(effect)
        frame = (f + 1) % total

        let matrix = render(effect, frame: f)
        inFlight = true
        Task { [weak self] in
            _ = await BackendService.shared.post("/api/rgb", [
                "mode": "matrix",
                "rows": matrix,
                "brightness": self?.bright ?? 75,
                "remember": false,
            ])
            self?.inFlight = false
        }
    }

    private func totalFrames(_ e: KeyboardEffect) -> Int {
        switch e {
        case .neon:   return 7     // 调色板 7 色
        case .stack:  return 45    // 15 组 × 3 色
        case .impact: return 20
        default:      return 1
        }
    }

    // MARK: - 画面生成

    private func blank() -> [[[Int]]] {
        Array(repeating: Array(repeating: [0, 0, 0], count: cols), count: rows)
    }

    /// 原厂索引 → 我们的 [row_screen][col]（row_phys 0 = 最下排）
    private func put(_ m: inout [[[Int]]], _ idx: Int, _ c: [Int]) {
        guard idx >= 0, idx < rows * cols else { return }
        let rowPhys = idx / cols
        let col = idx % cols
        let rowScreen = rows - 1 - rowPhys
        m[rowScreen][col] = c
    }

    private func color(_ i: Int) -> [Int] {
        guard !palette.isEmpty else { return [0, 0, 0] }
        return palette[i % palette.count]
    }

    private func render(_ e: KeyboardEffect, frame f: Int) -> [[[Int]]] {
        var m = blank()
        switch e {
        case .neon:
            // 整屏单色，逐帧换色（原厂 StaticMode）
            let c = color(f)
            for r in 0..<rows { for cc in 0..<cols { m[r][cc] = c } }

        case .impact:
            if f < 10 {
                // 左侧两列（palette[0]）+ 右侧两列（palette[1]），向中间收拢
                for col in [f, f + 1] { fillColumn(&m, col, color(0)) }
                for col in [20 - f, 19 - f] { fillColumn(&m, col, color(1)) }
            } else {
                // 从中心 10 往左扫（palette[2]）
                let g = f - 10
                for col in [10 - g, 9 - g] { fillColumn(&m, col, color(2)) }
            }

        case .stack:
            // 中心灯常亮 + 该帧的对称层（颜色每 15 帧换一次）
            let c = color(f / 15)
            put(&m, 52, c)
            let group = Self.stackFrames[(f % 15)]
            for idx in group { put(&m, idx, c) }

        default:
            break
        }
        return m
    }

    private func fillColumn(_ m: inout [[[Int]]], _ col: Int, _ c: [Int]) {
        guard col >= 0, col < cols else { return }
        for r in 0..<rows { m[r][col] = c }
    }
}
