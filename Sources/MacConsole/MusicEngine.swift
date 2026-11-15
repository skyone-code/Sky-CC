import Foundation
import CoreAudio
import AppKit
import Accelerate

// ============================================================================
// 音乐律动（2026-10-25 第二版：真正的频谱条）
//
// 【为什么必须自己做】固件码 0x22 只是一个编号，芯片自己不会分析音频。原厂的
// 音乐律动完全在上位机做 —— `audiostealer.dll` 抓默认输出设备 PCM → FFT →
// 把 RGB 写给键盘（08-GamingCenter逆向资料/02-文档/ControlCenter-功能全解.md
// 第 61、98 行；Keyboard-HID.md 的命令表里没有任何「音频」命令）。
//
// 【第一版错在哪】把 6 个频段各对应「键盘的一整行」，一行一个颜色。那不是频谱，
// 是 6 条横向色带 —— 用户一眼看出「音乐律动不应该是这样的动效」。
//
// 【第二版照业界做法重写】键盘音乐可视化的通用形态是**柱状频谱均衡器**
// （vertical bar equalizer），三份权威实现都是这个结构：
//   · SteelSeries GameSense audiovisualizer：把频率值映射到 key 的**列**，
//     每列是纵向 6 个 key，按电平比例**从下往上**点亮，超出部分纯黑
//   · Corsair KeyboardAudioVisualizer：「Frequency Bars」= 对数分组、
//     每组取功率和、可调 60Hz–15kHz、平滑 + 峰值强调
//   · QMK lazersync：每个频段 → 一列，值 = 该列点亮几行
// 所以这里：
//   列（21）= 频段（对数分组 55Hz → 16kHz，左低右高）
//   行（6） = 电平高度，**最底行先亮，往上长**
//   颜色     = 按频段取色相（低频红 → 高频紫），亮度按电平
//   另加 AGC（自适应峰值）+ 快起慢落包络 + 鼓点脉冲，避免闪烁和死黑。
//
// 链路：Core Audio process tap（macOS 14.2+，抓系统输出，不要屏幕录制权限）
//   → 私有聚合设备 → IOProc 取 Float32 立体声 → 2048 点 FFT（50% 重叠）
//   → 21 段电平 → 6×21 逐键颜色 → helper（mode=matrix，remember=false）
// 只在用户选「音乐律动」并点确定应用时启动；切走或关灯即停。
// ============================================================================

/// 频谱分析器：**只在音频线程访问**，不加锁（IOProc 是串行回调）。
final class MusicAnalyzer {
    /// 键盘 6 行 × 21 列 —— 分析结果直接就是一帧逐键颜色
    static let rows = 6
    static let cols = 21

    /// 2048 点 @48k ≈ 43ms 窗、23Hz/bin：低频分辨得动鼓点，高频也够用
    private let n = 2048
    private let hop = 1024                     // 50% 重叠，分析帧率上限 ~47fps
    private let log2n = vDSP_Length(11)
    private var setup: FFTSetup?
    private var hann: [Float] = []
    private var ring: [Float] = []
    private var mags: [Float]

    /// 频段 → FFT bin 区间（按采样率重算）
    private var bandLo = [Int](repeating: 1, count: MusicAnalyzer.cols)
    private var bandHi = [Int](repeating: 2, count: MusicAnalyzer.cols)

    /// 每段包络（快起慢落）
    private var env = [Float](repeating: 0, count: MusicAnalyzer.cols)
    /// **全局**自适应峰值（dB）。一条，不是每段各一条 ——
    /// 每段各归一（3.0.1.3 那版）的结果是「安静的高频段也被拉到满格」，
    /// 21 根柱子永远一样高，看着就不像跟着音乐走。
    private var peakDB: Float = -90
    /// 噪声底（dB）：缓慢上爬、立即下探。用来判「到底有没有在放声音」。
    private var noiseFloor: Float = 0

    /// 下发节流：~16fps。再快也只是让 XPC 排队（每帧 = 6 行 × 2 笔 HID）
    private let emitInterval: TimeInterval = 0.06
    private var lastEmit = Date.distantPast

    /// 曾经收到过非零采样吗。
    /// **TCC 未授权时 tap 照常创建、回调照常触发、数据全是 0** —— 这是唯一能识别
    /// 「被拒绝」还是「真的没在放音乐」的线索。音频线程写，主线程读。
    var sawSignal = false

    /// 采样率（建好聚合设备后由 MusicEngine 填），决定频段对应的 bin
    var sampleRate: Float = 48_000 {
        didSet { if sampleRate > 8_000 { rebuildBands() } }
    }

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        mags = [Float](repeating: 0, count: n / 2)
        ring.reserveCapacity(n * 2)
        rebuildBands()
    }

    deinit {
        if let s = setup { vDSP_destroy_fftsetup(s) }
    }

    /// 对数分组：人耳就是这么听的，线性分组会让低频只占一两列、高频挤成一片
    private func rebuildBands() {
        let fMin: Float = 55
        let fMax: Float = 16_000
        let top = Float(n / 2)
        let perBin = sampleRate / Float(n)
        for b in 0..<Self.cols {
            let t0 = Float(b) / Float(Self.cols)
            let t1 = Float(b + 1) / Float(Self.cols)
            let f0 = fMin * powf(fMax / fMin, t0)
            let f1 = fMin * powf(fMax / fMin, t1)
            var lo = Int((f0 / perBin).rounded(.down))
            var hi = Int((f1 / perBin).rounded(.up))
            lo = max(1, min(lo, Int(top) - 2))
            hi = max(lo + 1, min(hi, Int(top) - 1))
            bandLo[b] = lo
            bandHi[b] = hi
        }
    }

    /// 喂一段 PCM；攒够一帧、且到了下发间隔才返回这一帧的 6×21 颜色
    func push(_ p: UnsafePointer<Float>, _ count: Int) -> [[[Int]]]? {
        ring.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
        guard ring.count >= n else { return nil }
        var out: [[[Int]]]?
        while ring.count >= n {
            let slice = Array(ring[0..<n])
            analyze(slice)
            ring.removeFirst(hop)
            if Date().timeIntervalSince(lastEmit) >= emitInterval {
                lastEmit = Date()
                out = render()
            }
        }
        return out
    }

    private func analyze(_ x: [Float]) {
        guard let setup = setup else { return }
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(x, 1, hann, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        // ---- 21 段 dB（只算一遍，后面三个判断都吃这一份结果）
        var dbArr = [Float](repeating: -90, count: Self.cols)
        var program: Float = -90          // 节目电平 = 这一帧最响的那一段
        for b in 0..<Self.cols {
            let lo = bandLo[b], hi = bandHi[b]
            var power: Float = 0
            for k in lo..<hi { power += mags[k] * mags[k] }
            power /= Float(hi - lo)
            let db = 10 * log10f(power + 1e-12)
            dbArr[b] = db
            if db > program { program = db }
        }
        if program > -78 { sawSignal = true }

        // ---- 噪声底：立即下探、缓慢上爬（0.2dB/帧 ≈ 12dB/s）
        noiseFloor = noiseFloor == 0 ? program : min(program, noiseFloor + 0.2)

        // ---- 静音判定：电平趴在噪声底上 → 没在放声音，整块黑。
        // 这是「一开始都是黑的」那条要求的落点：不是靠 env 慢慢衰减到很小，
        // 而是只要没超过底噪 6dB，就直接归零。
        let active = program > noiseFloor + 6

        // ---- 全局峰值（AGC）：回落 0.45dB/帧 ≈ 27dB/s
        peakDB = max(program, peakDB - 0.45)
        let span: Float = 30              // 峰值往下 30dB 归 0

        for b in 0..<Self.cols {
            var v: Float = 0
            if active {
                v = (dbArr[b] - (peakDB - span)) / span
                v = min(1, max(0, v))
                if v < 0.08 { v = 0 }     // 门槛：宁可黑，也不挂一格毛刺
            }
            // 快起慢落：起音立刻跟上（打击乐有冲击力），回落约 200ms（不闪）
            env[b] = v > env[b] ? v : env[b] * 0.62 + v * 0.38
        }
    }

    /// 21 段电平 → 6 行 × 21 列颜色（柱状频谱：最底行先亮，往上长）
    private func render() -> [[[Int]]] {
        var out = [[[Int]]](repeating: [[Int]](repeating: [0, 0, 0], count: Self.cols),
                            count: Self.rows)
        for c in 0..<Self.cols {
            let v = env[c]
            if v <= 0.06 { continue }          // 静音 → 整列纯黑（不给底色）
            let h = v * Float(Self.rows)
            let full = min(Self.rows, Int(h))
            let frac = h - Float(full)
            let (r, g, b) = Self.bandColor(c)
            for row in 0..<Self.rows {
                // 数组是**屏幕顺序**（行 0 = 最上面的 F 排），所以最底行是 rows-1；
                // 芯片侧的物理行是反的（0 = 最下面），那个反转在
                // KeyboardRGB.setMatrixRows 里统一做，这里只管屏幕顺序。
                let level = Self.rows - 1 - row
                var k: Float = 0
                if level < full { k = 1 }
                else if level == full { k = frac }
                if k <= 0.05 { continue }
                let s = min(1, powf(k, 0.85))
                out[row][c] = [Int(Float(r) * s), Int(Float(g) * s), Int(Float(b) * s)]
            }
        }
        return out
    }

    /// 第 i 列的色相：低频红（0）→ 高频紫（0.78），绕开洋红回红那段
    static func bandColor(_ i: Int) -> (Int, Int, Int) {
        let t = Double(i) / Double(max(1, cols - 1))
        return hsv(t * 0.78, 1, 1)
    }

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Int, Int, Int) {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        var r = 0.0, g = 0.0, b = 0.0
        switch i {
        case 0: r = v; g = t; b = p
        case 1: r = q; g = v; b = p
        case 2: r = p; g = v; b = t
        case 3: r = p; g = q; b = v
        case 4: r = t; g = p; b = v
        default: r = v; g = p; b = q
        }
        return (Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

@MainActor
final class MusicEngine: ObservableObject {
    static let shared = MusicEngine()

    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    /// 起了但收不到声音时给出的解释（权限 / 没在放音乐），UI 直接显示
    @Published private(set) var hint: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let analyzer = MusicAnalyzer()
    private var watchdog: DispatchSourceTimer?

    var available: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    @discardableResult
    func start() -> Bool {
        guard !running else { return true }
        guard #available(macOS 14.2, *) else {
            lastError = "音乐律动需要 macOS 14.2 以上（Core Audio process tap）"
            return false
        }
        lastError = nil

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        desc.name = "MacConsole Music"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else {
            lastError = "无法创建音频 tap（\(st)）"
            return false
        }
        tapID = tap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacConsole Music",
            kAudioAggregateDeviceUIDKey: "com.macconsole.music.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard st == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            tapID = AudioObjectID(kAudioObjectUnknown)
            lastError = "无法创建聚合设备（\(st)）"
            return false
        }
        aggID = agg

        // 频段 → bin 的换算依赖真实采样率（48k / 44.1k / 外置声卡 96k 都不一样）
        var sr = Float64(48_000)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        if AudioObjectGetPropertyData(agg, &addr, 0, nil, &size, &sr) == noErr, sr > 8_000 {
            analyzer.sampleRate = Float(sr)
        }

        let analyzer = self.analyzer
        let forward: @Sendable ([[[Int]]]) -> Void = { self.send($0) }
        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, agg, nil) { _, inData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inData))
            guard let buf = list.first, let raw = buf.mData else { return }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let p = raw.assumingMemoryBound(to: Float.self)
            guard let frame = analyzer.push(p, count) else { return }
            forward(frame)
        }
        guard st == noErr, let proc = pid else {
            lastError = "无法建立音频回调（\(st)）"
            stop()
            return false
        }
        procID = proc
        st = AudioDeviceStart(agg, proc)
        guard st == noErr else {
            lastError = "无法开始采集（\(st)）"
            stop()
            return false
        }
        analyzer.sawSignal = false
        hint = nil
        running = true
        startWatchdog()
        return true
    }

    /// 起了却没声音时的自检。
    ///
    /// 为什么要这个：`kTCCServiceAudioCapture`（系统设置 →「屏幕与系统音频录制」→
    /// 「仅系统音频录制」）没授权时，**MAC 不会报错** —— tap 创建成功、回调照常
    /// 触发、每个采样都是 0.0，看上去和「刚好没放音乐」一模一样。不说清楚的话，
    /// 用户只会觉得「音乐律动没用」。
    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2.5, repeating: 2.5)
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.analyzer.sawSignal {
                self.hint = nil
                self.watchdog?.cancel()
                self.watchdog = nil
            } else if self.hint == nil {
                self.hint = "收不到声音：如果正在放音乐，多半是「仅系统音频录制」没授权"
            }
        }
        t.resume()
        watchdog = t
    }

    /// 直接跳到「屏幕与系统音频录制」这一页，省得用户自己找
    static func openPrivacySettings() {
        for s in ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        hint = nil
        if let proc = procID {
            AudioDeviceStop(aggID, proc)
            AudioDeviceDestroyIOProcID(aggID, proc)
            procID = nil
        }
        if aggID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        running = false
    }

    /// 一帧 6×21 逐键颜色 → helper（nonisolated：从音频回调线程直接调用）
    nonisolated private func send(_ rows: [[[Int]]]) {
        Task {
            _ = await BackendService.shared.post("/api/rgb",
                ["mode": "matrix", "rows": rows, "remember": false])
        }
    }
}
