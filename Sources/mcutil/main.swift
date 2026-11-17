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
      sys [overview|battery|disks|processes|all]
                                  系统信息全量导出（默认 all）
    """
    print(text)
    exit(1)
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

if cmd != "xpc", helperRunning(), !CommandLine.arguments.contains("--force") {
    let isWrite = (cmd == "fan" || cmd == "rgb")
    if isWrite {
        fail("后台服务正在运行，它独占 EC/SMC 通道，直写会与其争用。\n"
             + "  建议改用 app 界面或 HTTP 接口；确需强来加 --force")
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

default:
    usage()
}
