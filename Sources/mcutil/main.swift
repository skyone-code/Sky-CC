//
//  main.swift
//  mcutil —— Sky CC硬件命令行助手（原生，无 Python）
//
//  替代旧版 app-resources/ 下 bright.py / rgbkb.py 的命令行用法：
//     mcutil rgb profile             打印保存的键盘灯效（无配置时打印 (无配置)）
//     mcutil rgb apply               应用保存的键盘灯效（登录恢复用，带重试由调用方决定）
//     mcutil rgb clear               清除保存的灯效
//     mcutil fan status              风扇/EC 状态（排障用）
//     mcutil sensors                 SMC 传感器快照（排障用）
//
//  随 app 打包在 Contents/MacOS/mcutil（与主程序共用 Native/*.swift），
//  因此在 app bundle 内运行时 Bundle.main 指向 app，可找到 native/bin/ 下的
//  nvmetemp。独立运行时回退 ~/bin 与 /usr/local/bin。
//
//  退出码：0 成功；1 用法错误；2 硬件操作失败（ok:false）。
//

import Foundation

// MARK: - JSON 输出（键序稳定，便于人读与 grep）

func printJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{\"ok\": false, \"error\": \"json encode failed\"}")
    }
}

func fail(_ msg: String) -> Never {
    printJSON(["ok": false, "error": msg])
    exit(2)
}

func usage() -> Never {
    let text = """
    用法: mcutil <命令> [参数]

      rgb profile                 打印保存的键盘灯效（无配置输出 (无配置)）
      rgb apply                   应用保存的键盘灯效
      rgb clear                   清除保存的键盘灯效
      fan status                  风扇/EC 状态
      sensors                     SMC 传感器快照
      xpc ping                    后台服务健康检查（走 XPC）
      xpc get /api/fan            直接问后台服务取数（等价旧 curl）
      xpc post /api/fan '{"thermal":2}'
                                  向后台服务提交操作
      sys [overview|battery|disks|processes|all]
                                  系统信息全量导出（默认 all）

    ── 以下为「快捷指令 / 命令行控制」（全部经 XPC 交后台服务执行）──

      status                      状态速览（散热/充电阈值/开关组）
      thermal <1|2|3>             散热模式（1性能 2标准 3安静）
      charge <20-100>             充电阈值（%）
      kb <on|off>                 键盘灯总开关
      lightbar <cycle|static|off> 海岸灯
      apbeat <on|off>             AP 心跳
      winlock <on|off>            Win 键锁定
      fnlock <on|off>             Fn 锁
      gpu <on|off>                独显注入（新启动的 app 生效）
      volume <0-100>              系统音量
      mute | unmute               静音 / 取消静音
      displaysleep                关闭内屏

    手机快捷指令用法：iPhone「快捷指令」→「通过 SSH 运行脚本」连接本机
    （Mac 需在系统设置开启「远程登录」），执行上面任意一条命令。
    """
    print(text)
    exit(1)
}

// MARK: - XPC 调用（3.2.2 从 "xpc" 分支提升到顶层：新增控制命令同样要经 XPC
// 让后台服务执行，mcutil 直写会与 helper 争用 EC 串行通道）

func xpcCall(_ path: String, _ params: [String: Any]?) -> [String: Any] {
    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any] = ["ok": false, "error": "no reply"]
    Task {
        out = await HelperClient.shared.call(path, params: params, timeout: 15)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
    return out
}

func xpcPing() -> [String: Any] {
    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any] = ["ok": false, "error": "no reply"]
    Task {
        out = await HelperClient.shared.health(timeout: 3)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    return out
}

// MARK: - 快捷指令 / 命令行控制（3.2.2）
//
// 硬件控制命令组，全部经 XPC 交后台 helper 执行（mcutil 直写会争用 EC 串行通道）。
// 手机快捷指令：iPhone「通过 SSH 运行脚本」→ 连本机 → 执行任意一条；
// 本机快捷指令：「运行 Shell 脚本」动作调同一条命令。

/// 解析 on/off（大小写不敏感）
func parseOnOff(_ s: String) -> Bool? {
    switch s.lowercased() {
    case "on", "1", "true", "开": return true
    case "off", "0", "false", "关": return false
    default: return nil
    }
}

/// 快捷指令组：散热/充电阈值/键盘灯/海岸灯/AP 心跳/Win 锁/Fn 锁/独显/音量/关屏
func runCliControl(_ sub: String, _ rest: [String]) -> Never {
    func expectArg(_ what: String) -> String {
        guard let a = rest.first else {
            printJSON(["ok": false, "error": "缺少参数：\(what)"])
            exit(1)
        }
        return a
    }
    let r: [String: Any]
    switch sub {
    case "status":
        let fan = xpcCall("/api/fan", nil)
        guard fan["ok"] as? Bool == true else { r = fan; break }
        var out: [String: Any] = ["ok": true]
        for k in ["thermal_level", "power_level", "benchmark"] {
            if let v = fan[k] { out[k] = v }
        }
        if let c = fan["charge"] as? [String: Any] { out["charge"] = c }
        if let m = fan["misc"] as? [String: Any] { out["misc"] = m }
        r = out
    case "thermal":
        let a = expectArg("1|2|3")
        guard let n = Int(a), (1...3).contains(n) else {
            printJSON(["ok": false, "error": "散热模式取值 1(性能)/2(标准)/3(安静)"])
            exit(1)
        }
        r = xpcCall("/api/fan", ["thermal": n])
    case "charge":
        let a = expectArg("20-100")
        guard let n = Int(a), (20...100).contains(n) else {
            printJSON(["ok": false, "error": "充电阈值取值 20-100（百分比）"])
            exit(1)
        }
        r = xpcCall("/api/fan", ["charge": n])
    case "kb":
        let on = expectArg("on|off")
        guard let b = parseOnOff(on) else {
            printJSON(["ok": false, "error": "kb 取值 on|off"])
            exit(1)
        }
        // 开 = 应用存档灯效（helper 侧先置使能再覆盖）；关 = HID 关灯报文 + 存档置 disabled
        r = b ? xpcCall("/api/rgb/apply", [:]) : xpcCall("/api/rgb", ["mode": "off"])
    case "lightbar":
        let m = expectArg("cycle|static|off")
        guard ["cycle", "static", "off"].contains(m) else {
            printJSON(["ok": false, "error": "lightbar 取值 cycle|static|off"])
            exit(1)
        }
        r = xpcCall("/api/lightbar", ["mode": m])
    case "apbeat":
        let a = expectArg("on|off")
        guard let b = parseOnOff(a) else {
            printJSON(["ok": false, "error": "apbeat 取值 on|off"])
            exit(1)
        }
        r = xpcCall("/api/fan", ["ap_present": b])
    case "winlock":
        let a = expectArg("on|off")
        guard let b = parseOnOff(a) else {
            printJSON(["ok": false, "error": "winlock 取值 on|off"])
            exit(1)
        }
        // 与 Win 键锁定开关同款副作用：EC 会额外抛一次 PWRBTN，可能触发关屏/睡眠
        r = xpcCall("/api/fan", ["win_lock": b])
    case "fnlock":
        let a = expectArg("on|off")
        guard let b = parseOnOff(a) else {
            printJSON(["ok": false, "error": "fnlock 取值 on|off"])
            exit(1)
        }
        r = xpcCall("/api/fan", ["fn_lock": b])
    case "gpu":
        let a = expectArg("on|off")
        guard let b = parseOnOff(a) else {
            printJSON(["ok": false, "error": "gpu 取值 on|off"])
            exit(1)
        }
        r = xpcCall("/api/gpu/mode", ["mode": b ? "dgpu" : "off"])
    case "volume":
        let a = expectArg("0-100")
        guard let n = Int(a), (0...100).contains(n) else {
            printJSON(["ok": false, "error": "volume 取值 0-100"])
            exit(1)
        }
        r = xpcCall("/api/control", ["action": "volume", "value": n])
    case "mute":
        r = xpcCall("/api/control", ["action": "mute"])
    case "unmute":
        r = xpcCall("/api/control", ["action": "unmute"])
    case "displaysleep":
        r = xpcCall("/api/control", ["action": "display_sleep"])
    default:
        usage()
    }
    printJSON(r)
    if r["ok"] as? Bool != true { exit(2) }
    exit(0)
}

// --force 只是互斥开关，不参与命令解析
let args = CommandLine.arguments.dropFirst().filter { $0 != "--force" }
guard let cmd = args.first else { usage() }
let rest = Array(args.dropFirst())

// MARK: - 与后台 helper 互斥（2.6.0）
//
// helper 是 EC/SMC/HID 的唯一持有者。mcutil 直调会和它抢同一把串行通道
// （单次 EC 读 ~65ms、物理上限 ~15 次/秒）—— 历史上 /api/fan 从 4s 退化到
// 16s 就是这么来的。helper 在跑时：只读放行但提示，写入直接拒绝。
func helperRunning() -> Bool {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SkyCC/helper.lock").path
    guard let fd = fopen(path, "r") else { return false }
    defer { fclose(fd) }
    return flock(fileno(fd), LOCK_SH | LOCK_NB) != 0   // 拿不到共享锁＝别人持有排他锁
}

/// 快捷指令组命令：全部经 XPC 交后台服务执行，不与 helper 争用通道
let CliControlCommand: Set<String> = [
    "status", "thermal", "charge", "kb", "lightbar", "apbeat",
    "winlock", "fnlock", "gpu", "volume", "mute", "unmute", "displaysleep",
]

if cmd != "xpc", !CliControlCommand.contains(cmd), helperRunning(), !CommandLine.arguments.contains("--force") {
    let isWrite = (cmd == "fan" || cmd == "rgb")
    if isWrite {
        fail("后台服务正在运行，它独占 EC/SMC 通道，直写会与其争用。\n"
             + "  建议改用 app 界面或 XPC 接口；确需强来加 --force")
    }
    FileHandle.standardError.write(
        Data("提示：后台服务在运行，本次直读会与其争用 EC 通道（排障可忽略）\n".utf8))
}

switch cmd {

// MARK: - 键盘灯效

case "rgb":
    guard let sub = rest.first else { usage() }
    switch sub {
    case "profile":
        if let prof = RGBProfile.load() {
            printJSON(prof)
        } else {
            // 与旧版 rgbkb.py profile 一致：无配置时打印这一行，
            // restore_rgb.sh 靠 grep "^(无配置)" 判断跳过
            print("(无配置)")
        }
    case "apply":
        let r = RGBProfile.apply()
        printJSON(r)
        if r["ok"] as? Bool != true { exit(2) }
    case "clear":
        let ok = RGBProfile.clear()
        printJSON(["ok": ok])
        if !ok { exit(2) }
    default:
        usage()
    }

// MARK: - 排障命令

case "fan":
    guard rest.first == "status" else { usage() }
    printJSON(FanControl.shared.fanStatus())

case "xpc":
    // 2.6.0 起没有 HTTP 了：这是命令行访问后台 helper 的入口
    //   mcutil xpc ping            健康检查（版本/pid/kext）
    //   mcutil xpc get /api/fan    等价于旧的 curl /api/fan
    guard let sub = rest.first else { usage() }
    switch sub {
    case "ping":
        printJSON(xpcPing())
    case "get":
        guard let path = rest.dropFirst().first else { usage() }
        printJSON(xpcCall(path, nil))
    case "post":
        // mcutil xpc post /api/fan '{"thermal":2}'
        guard let path = rest.dropFirst().first,
              let json = rest.dropFirst(2).first,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { usage() }
        printJSON(xpcCall(path, obj))
    default:
        usage()
    }

case "sensors":
    printJSON(SMCSnapshot.snapshot())

case "dgpu":
    // 独显利用率（NVAccel 发布的 PerformanceStatistics，驱动 2.6.3 起）：
    // 诊断驱动到底有没有上报。读一次 IORegistry 就够，sampleOnce() 与 snapshot() 等价。
    printJSON(NVAccelUtil.sampleOnce())

case "sys":
    // 系统信息全量导出（与 HTTP 接口同一套采集函数），排障/对账用
    switch rest.first ?? "all" {
    case "overview":  printJSON(NativeSystem.overview())
    case "battery":   printJSON(NativeSystem.battery())
    case "disks":     printJSON(NativeSystem.disks())
    case "processes": printJSON(NativeSystem.processes(limit: 20))
    case "all":
        var payload: [String: Any] = [:]
        payload["overview"] = NativeSystem.overview()
        payload["battery"] = NativeSystem.battery()
        payload["disks"] = NativeSystem.disks()
        payload["processes"] = NativeSystem.processes(limit: 20)
        printJSON(payload)
    default:
        usage()
    }

// MARK: - 快捷指令 / 命令行控制（实验性，走 XPC）
//
// 手机快捷指令（iPhone「通过 SSH 运行脚本」→ 连本机 → 执行命令）与本机
// 快捷指令（「运行 Shell 脚本」动作）共用这一组。

case "status", "thermal", "charge", "kb", "lightbar", "apbeat",
     "winlock", "fnlock", "gpu", "volume", "mute", "unmute", "displaysleep":
    runCliControl(cmd, rest)

default:
    usage()
}
