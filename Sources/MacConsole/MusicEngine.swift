import Foundation
import CoreAudio
import Accelerate

// ============================================================================
// 音乐律动（2026-10-25）
//
// 为什么原来的「音乐律动」是死的：
//   固件码 0x22 只是一个编号，芯片自己不会分析音频。原厂的音乐律动完全在
//   上位机做 —— `audiostealer.dll` 抓默认输出设备的 PCM → FFT → 实时把 RGB
//   写给键盘（08-GamingCenter逆向资料/02-文档/ControlCenter-功能全解.md
//   第 61、98 行；Keyboard-HID.md 的命令表里也没有任何「音频」命令）。
//   所以我们只发一条 0x08 effect=0x22 的结果就是：芯片停在它自己的静态画面上，
//   也就是用户看到的「白色常亮」。
//
// 这里把上位机那一半补上：
//   Core Audio process tap（macOS 14.2+，抓系统输出，不需要屏幕录制权限）
//     → 私有聚合设备 → IOProc 拿 Float32 立体声
//     → 1024 点 FFT → 6 个频段电平
//     → 每 1/12 秒把 6 行颜色写给键盘（mode=zones，remember=false，不污染存档）
//
// 只在用户选了「音乐律动」并点确定应用时启动；切走或关灯即停。
// ============================================================================

/// 频谱分析器：**只在音频线程访问**，不加锁（IOProc 是串行回调）。
final class MusicAnalyzer {
    private let n = 1024
    private let log2n = vDSP_Length(10)
    private var setup: FFTSetup?
    private var hann: [Float] = []
    private var acc: [Float] = []
    private var levels = [Float](repeating: 0, count: 6)
    private var peaks = [Float](repeating: 0.02, count: 6)
    /// 1024 点 @48kHz ≈ 21ms 一帧；每 4 帧出一次 ≈ 12Hz，够顺滑又不占 HID
    private var frames = 0
    private let every = 4

    /// 6 个频段的起始 bin（48kHz / 1024 点 → 每 bin 46.9Hz）
    private let edges = [1, 2, 5, 13, 32, 75, 192]

    /// 六个频段的代表色：低频暖 → 高频冷
    static let bandColors: [(Int, Int, Int)] = [
        (255, 40, 24), (255, 140, 0), (255, 220, 0),
        (40, 255, 90), (0, 200, 255), (150, 90, 255),
    ]

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        hann = [Float](repeating: 0, count: n)
        vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        acc.reserveCapacity(n)
    }

    deinit {
        if let s = setup { vDSP_destroy_fftsetup(s) }
    }

    /// 喂一段 PCM；凑满一帧、且到了下发间隔才返回 6 段电平（0…1）
    func push(_ p: UnsafePointer<Float>, _ count: Int) -> [Float]? {
        var i = 0
        while i < count {
            let take = min(n - acc.count, count - i)
            acc.append(contentsOf: UnsafeBufferPointer(start: p + i, count: take))
            i += take
            if acc.count == n {
                let out = analyze()
                acc.removeAll(keepingCapacity: true)
                frames &+= 1
                if frames % every == 0 { return out }
            }
        }
        return nil
    }

    private func analyze() -> [Float]? {
        guard let setup = setup else { return nil }
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(acc, 1, hann, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)

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

        // 每段取 RMS，再按「自己历史峰值」归一化 —— 不用猜增益，大小音量都能看
        for b in 0..<6 {
            let lo = min(edges[b], n / 2 - 1)
            let hi = min(max(edges[b + 1], lo + 1), n / 2)
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] * mags[k] }
            let rms = (sum / Float(hi - lo)).squareRoot()
            peaks[b] = max(rms, peaks[b] * 0.99, 0.02)
            let v = min(1, rms / peaks[b])
            levels[b] = max(v, levels[b] * 0.72)   // 起得快、落得慢，看起来更像律动
        }
        return levels
    }
}

@MainActor
final class MusicEngine: ObservableObject {
    static let shared = MusicEngine()

    @Published private(set) var running = false
    @Published private(set) var lastError: String?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let analyzer = MusicAnalyzer()

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

        let analyzer = self.analyzer
        let forward: @Sendable ([Float]) -> Void = { self.send($0) }
        var pid: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, agg, nil) { _, inData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inData))
            guard let buf = list.first, let raw = buf.mData else { return }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { return }
            let p = raw.assumingMemoryBound(to: Float.self)
            guard let levels = analyzer.push(p, count) else { return }
            forward(levels)
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
        running = true
        return true
    }

    func stop() {
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

    /// 6 段电平 → 6 行颜色 → helper（nonisolated：从音频回调线程直接调用）
    nonisolated private func send(_ levels: [Float]) {
        let zones: [[Int]] = (0..<6).map { b in
            let c = MusicAnalyzer.bandColors[b]
            // 留一点底光，安静时不至于全黑
            let k = 0.10 + 0.90 * Double(levels[b])
            return [Int(Double(c.0) * k), Int(Double(c.1) * k), Int(Double(c.2) * k)]
        }
        Task {
            _ = await BackendService.shared.post("/api/rgb",
                ["mode": "zones", "zones": zones, "remember": false])
        }
    }
}
