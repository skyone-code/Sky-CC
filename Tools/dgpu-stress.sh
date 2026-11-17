#!/bin/zsh
# dgpu-stress.sh —— 给 dGPU 加压，同时采样利用率，验证读数是否真的跟随负载
#
# 用法：
#   ./Tools/dgpu-stress.sh                 # 满载 20 秒 + 3 秒基线 + 5 秒回落
#   ./Tools/dgpu-stress.sh 30              # 满载 30 秒
#   ./Tools/dgpu-stress.sh 20 50           # 20 秒、占空比 50%（跑一半歇一半）
#   ./Tools/dgpu-stress.sh 15 100 2        # 每 2 秒采一次（默认 1 秒）
#
# 为什么要占空比：驱动报的 GR 利用率是「引擎忙碌时间占比」。满载只能验证
# 「能不能打满」，占空比 50% 才能验证「读数是否与真实负载成正比」—— 后者
# 才能排除「驱动写了个固定值」这种假上报。
#
# 采样方式：直接读 NVAccel 的 PerformanceStatistics（驱动 2.6.3 起由内核每秒采样，
# 见 Sources/SkyCC/Native/NativeNVAccel.swift）。不需要 root、不需要 app 在跑、
# 也不需要自己开 RM 通道。两个要记住的语义：驱动**每秒**才更新一次，采样间隔低于
# 1 秒只会看到重复值；查询失败或样本超 5 秒没更新时驱动是**删键**而不是写 0。
#
# 依赖：Xcode 命令行工具（swiftc）、Metal。
#
# 退出码：0 正常；1 找不到 dGPU；2 编译失败；3 Metal 管线构建失败。

set -u

# 脚本所在目录的上一级 = 项目根
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/Sources/SkyCC/Native/NativeNVAccel.swift"

if [[ ! -f "$NATIVE" ]]; then
    print -u2 "错误：找不到 $NATIVE"
    print -u2 "这个脚本必须放在项目的 Tools/ 目录下运行。"
    exit 1
fi

SECS="${1:-20}"
DUTY="${2:-100}"
INTERVAL="${3:-1}"

WORK="$(mktemp -d /tmp/dgpu-stress.XXXXXX)" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import Metal

// MARK: - 参数

let argv = CommandLine.arguments
let loadSeconds      = argv.count > 1 ? (Double(argv[1]) ?? 20) : 20
let duty             = argv.count > 2 ? min(max(Int(argv[2]) ?? 100, 1), 100) : 100
let sampleInterval   = argv.count > 3 ? max(Double(argv[3]) ?? 1, 0.2) : 1.0
let baselineSeconds  = 3.0
let cooldownSeconds  = 5.0

func die(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write("错误：\(msg)\n".data(using: .utf8)!)
    exit(code)
}

// MARK: - 选设备
//
// 这台机器有 iGPU + dGPU。Metal 的默认设备是 iGPU，必须显式挑 NVIDIA 那块 ——
// 压到 iGPU 上的话 dGPU 的 GR 读数当然一直是 0，测了等于没测。

let devices = MTLCopyAllDevices()
guard !devices.isEmpty else { die("没有可用的 Metal 设备", 1) }

guard let dev = devices.first(where: { $0.name.uppercased().contains("NVIDIA") }) else {
    print("可用的 Metal 设备：")
    for d in devices { print("  · \(d.name)") }
    die("没找到 NVIDIA 设备。压测必须打在 dGPU 上，否则 GR 读数不会动。", 1)
}

print("设备：\(dev.name)")
print("参数：基线 \(Int(baselineSeconds))s → 加压 \(Int(loadSeconds))s（占空比 \(duty)%）→ 回落 \(Int(cooldownSeconds))s，采样间隔 \(sampleInterval)s")
print("")

// MARK: - 管线

let kernelSource = """
#include <metal_stdlib>
using namespace metal;

kernel void spin(device float *out        [[buffer(0)]],
                 constant uint &rounds    [[buffer(1)]],
                 uint i                   [[thread_position_in_grid]]) {
    float x = float(i) + 1.0f;
    for (uint k = 0; k < rounds; k++) {
        x = fma(x, 1.0000001f, 1.0f);
        x = sqrt(fabs(x));
    }
    out[i] = x;
}
"""

guard let lib = try? dev.makeLibrary(source: kernelSource, options: nil),
      let fn  = lib.makeFunction(name: "spin"),
      let pipe = try? dev.makeComputePipelineState(function: fn) else {
    die("Metal 管线构建失败（设备可能不支持从源码编译）", 3)
}

let threadCount = 1 << 20          // 1M 线程，足够喂满 2070S 的 SM
let rounds: UInt32 = 30000         // 每个线程的 FMA+sqrt 迭代数
let tg = MTLSize(width: 64, height: 1, depth: 1)
let grid = MTLSize(width: threadCount, height: 1, depth: 1)

guard let buf = dev.makeBuffer(length: threadCount * 4, options: .storageModeShared),
      let queue = dev.makeCommandQueue() else {
    die("Metal buffer / queue 创建失败", 3)
}

var roundsValue = rounds
guard let roundsBuf = dev.makeBuffer(bytes: &roundsValue, length: 4, options: .storageModeShared) else {
    die("rounds buffer 创建失败", 3)
}

/// 提交一次 compute，并等它跑完。返回这次 dispatch 的墙钟耗时（秒）。
@discardableResult
func dispatchOnce() -> Double {
    let t0 = Date()
    guard let cb = queue.makeCommandBuffer(),
          let enc = cb.makeComputeCommandEncoder() else { return 0 }
    enc.setComputePipelineState(pipe)
    enc.setBuffer(buf, offset: 0, index: 0)
    enc.setBuffer(roundsBuf, offset: 0, index: 1)
    enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    return Date().timeIntervalSince(t0)
}

// MARK: - 采样线程
//
// 和加压并行跑：主线程在 dispatch，采样线程每秒打一次 IORegistry。
// sampleOnce() 只是一次属性读（微秒级），放独立线程纯粹是为了不打乱加压节奏；
// 驱动的采样周期是 1 秒，所以这里取到的值和上一拍重复是正常的。

final class Recorder {
    struct Row { let t: Double; let phase: String; let gr: Double; let a5: Double; let a15: Double }
    private let lock = NSLock()
    private var rows: [Row] = []
    private var _phase = "基线"
    private var _stop = false

    var phase: String {
        get { lock.lock(); defer { lock.unlock() }; return _phase }
        set { lock.lock(); _phase = newValue; lock.unlock() }
    }
    var stop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stop }
        set { lock.lock(); _stop = newValue; lock.unlock() }
    }
    func append(_ r: Row) { lock.lock(); rows.append(r); lock.unlock() }
    var all: [Row] { lock.lock(); defer { lock.unlock() }; return rows }
}

let rec = Recorder()
let startTime = Date()

let sampler = Thread {
    while true {
        if rec.stop { break }
        let s = NVAccelUtil.sampleOnce()
        let gr  = (s["gr_pct"]       as? Double) ?? 0
        let a5  = (s["gr_avg5_pct"]  as? Double) ?? 0
        let a15 = (s["gr_avg15_pct"] as? Double) ?? 0
        let t   = Date().timeIntervalSince(startTime)
        let ph  = rec.phase

        rec.append(.init(t: t, phase: ph, gr: gr, a5: a5, a15: a15))

        // 三个阶段名都是两个汉字，等宽，不需要再 padding
        print(String(format: "[%@] t=%5.1fs   gr=%6.2f%%   avg5=%6.2f%%   avg15=%6.2f%%",
                     ph, t, gr, a5, a15))
        fflush(stdout)

        Thread.sleep(forTimeInterval: sampleInterval)
    }
}
sampler.start()

// MARK: - 三段式：基线 → 加压 → 回落
//
// 先记基线是必须的：如果基线本来就不是 0（比如驱动写死了一个值），
// 单看加压期的数字会误判成「上报正常」。

Thread.sleep(forTimeInterval: baselineSeconds)

rec.phase = "加压"
let loadEnd = Date().addingTimeInterval(loadSeconds)
var dispatches = 0
var busySeconds = 0.0

while Date() < loadEnd {
    let work = dispatchOnce()
    dispatches += 1
    busySeconds += work
    // 占空比：跑 work 秒就按比例歇够，凑出 duty% 的忙碌时间
    if duty < 100 {
        let rest = work * Double(100 - duty) / Double(duty)
        if rest > 0.001 { Thread.sleep(forTimeInterval: rest) }
    }
}

rec.phase = "回落"
Thread.sleep(forTimeInterval: cooldownSeconds)

rec.stop = true
sampler.cancel()

// MARK: - 汇总

let rows = rec.all
func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

let base = rows.filter { $0.phase == "基线" }
let load = rows.filter { $0.phase == "加压" }
let cool = rows.filter { $0.phase == "回落" }
// 均值本身要 5 秒才爬满，前 2 秒的爬坡段不算峰值，否则会低估真实上限
let loadSteady = load.filter { $0.t - baselineSeconds >= 2.0 }

print("")
print("──────────────── 汇总 ────────────────")
print(String(format: "dispatch    %d 次，GPU 忙 %.1f 秒 / 墙钟 %.1f 秒（实际占空比 %.1f%%）",
             dispatches, busySeconds, loadSeconds, loadSeconds > 0 ? busySeconds / loadSeconds * 100 : 0))
print(String(format: "基线        gr 均值 %6.2f%%（%d 个样本）", avg(base.map(\.gr)), base.count))
print(String(format: "加压        gr 峰值 %6.2f%%   均值 %6.2f%%",
             load.map(\.gr).max() ?? 0, avg(load.map(\.gr))))
print(String(format: "            avg5 峰值 %6.2f%%   avg15 峰值 %6.2f%%",
             load.map(\.a5).max() ?? 0, load.map(\.a15).max() ?? 0))
print(String(format: "回落末段    gr 均值 %6.2f%%", avg(cool.suffix(3).map(\.gr))))

print("")
let baseGr = avg(base.map(\.gr))
let peakGr = loadSteady.map(\.gr).max() ?? load.map(\.gr).max() ?? 0
let peakA5 = load.map(\.a5).max() ?? 0

if baseGr > 20 {
    print("⚠️  基线就有 \(String(format: "%.1f", baseGr))% —— 跑之前 dGPU 就没闲着，")
    print("    或者驱动在上报一个固定值。先关掉其它 GPU 程序再测一次。")
} else if peakA5 < 3 && peakGr < 3 {
    print("❌ 加压期间读数没有跟随 —— GR 一直是 \(String(format: "%.2f", peakGr))%。")
    print("    可能是：驱动没上报、或者压测打在了 iGPU 上（看上面「设备」那一行）。")
} else {
    let ratio = duty > 0 ? peakGr / Double(duty) * 100 : 0
    print(String(format: "✅ 读数跟随负载：峰值 %.1f%% vs 占空比 %d%%（达成率 %.0f%%）",
                 peakGr, duty, ratio))
    if ratio < 70 {
        print("   达成率偏低通常是因为 dispatch 之间有空档（每次 waitUntilCompleted 后有间隙），")
        print("   不代表上报有问题 —— 看 avg5/avg15 的爬升形状更可靠。")
    }
}
SWIFT

# ── 编译 ───────────────────────────────────────────────────────────────
# 只链 NativeNVAccel.swift：它是自包含的（IOKit + Foundation），
# 不依赖 app 的其它源码，也不依赖 helper 是否在跑。
swiftc -O -o "$WORK/stress" "$NATIVE" "$WORK/main.swift" || {
    print -u2 "编译失败（检查 swiftc 是否可用：xcode-select -p）"
    exit 2
}

"$WORK/stress" "$SECS" "$DUTY" "$INTERVAL"
