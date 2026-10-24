import Foundation

/// 界面记忆层（2.8.8，用户要求）
///
/// 用户原话：「建议软件记忆选择的各个项的值，不靠每次读 EC 来获取，
/// 读取 EC 只在打开软件的初始化阶段读取」。
///
/// 设计：
///   · 每次启动后**第一次**拿到 EC 快照时，把硬件真值写进这里（seedIfNeeded）
///   · 之后界面所有开关 / 档位都从这里的记忆值渲染，不再每轮去读 EC
///   · 用户每改一项，先写记忆、再写 EC，界面立刻以记忆为准
///
/// 好处：界面不再「点完 1 秒后被回读刷回去」；EC 的字节本来就是持久项，
/// 我们只是自己留一份权威副本，省掉每轮的读-改-写与竞态。
/// 代价：在别的系统（Windows / mcutil / 命令行）里改了同一项，界面要重启才发现。
enum UIControlPrefs {

    private static let d = UserDefaults.standard
    private static var seeded = false

    // MARK: - 键
    enum K {
        // 控制页
        static let thermal = "pref.control.thermal"        // "1"/"2"/"3"
        static let perfIndex = "pref.control.perfIndex"    // 0x11/0x22/0x33
        static let benchmark = "pref.control.benchmark"
        static let charge = "pref.control.charge"          // 20…100
        static let kbBacklight = "pref.control.kbBacklight"
        static let winLock = "pref.control.winLock"
        static let osd = "pref.control.osd"
        static let silentMode = "pref.control.silentMode"
        static let passiveCooling = "pref.control.passiveCooling"
        /// caffeinate（不是 EC 状态，但也统一走软件记忆，避免每进页面探一次进程）
        static let caffeinate = "pref.control.caffeinate"
        // 实验性页
        static let fanMode = "pref.exp.fanMode"            // normal/custom/curve
        static let fanLevel = "pref.exp.fanLevel"          // 0…7
        static let fnLock = "pref.exp.fnLock"
        // 灯效页
        static let lightbarMode = "pref.rgb.lightbarMode"  // cycle/static/off
        static let lightbarHex = "pref.rgb.lightbarHex"
    }

    // MARK: - 读
    static func bool(_ key: String) -> Bool? {
        d.object(forKey: key) == nil ? nil : d.bool(forKey: key)
    }
    static func int(_ key: String) -> Int? {
        d.object(forKey: key) == nil ? nil : d.integer(forKey: key)
    }
    static func string(_ key: String) -> String? {
        d.string(forKey: key)
    }

    // MARK: - 写
    static func set(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
    }

    /// `/api/fan` 的参数名 → 记忆键（开关类都走这条映射）
    static func prefKey(forFanKey fanKey: String) -> String? {
        switch fanKey {
        case "keyboard_backlight": return K.kbBacklight
        case "win_lock": return K.winLock
        case "osd": return K.osd
        case "silent_mode": return K.silentMode
        case "passive_cooling_disabled": return K.passiveCooling
        case "fn_lock": return K.fnLock
        default: return nil
        }
    }

    // MARK: - 初始化播种（每次启动只做一次）
    //
    // 只在「本次运行第一次拿到有效 EC 快照」时调用。之后再怎么轮询都不会覆盖记忆。
    // @MainActor：里面要用 BackendService.int/bool（它们访问的是主线程上的快照）。
    @MainActor
    static func seedIfNeeded(_ fan: [String: Any]) {
        guard !seeded, !fan.isEmpty else { return }
        seeded = true

        // 已经播种过（进程内）就不再动；但如果某个键缺失，补一次
        if let t = BackendService.int(fan, "thermal_level"), (1...3).contains(t),
           d.string(forKey: K.thermal) == nil {
            d.set(String(t), forKey: K.thermal)
        }
        if let mi = BackendService.int(fan, "modeindex"), [0x11, 0x22, 0x33].contains(mi),
           d.object(forKey: K.perfIndex) == nil {
            d.set(mi, forKey: K.perfIndex)
        }
        if let b = BackendService.bool(fan, "benchmark"), d.object(forKey: K.benchmark) == nil {
            d.set(b, forKey: K.benchmark)
        }
        if let ch = BackendService.int(fan, "charge"), d.object(forKey: K.charge) == nil {
            d.set(ch, forKey: K.charge)
        }
        // 风扇的高级模式：EC 的 mode 是运行态（曲线模式在 EC 眼里也是 custom），
        // 首次播种只用它兜底，之后以用户在实验性页选的为准。
        if d.string(forKey: K.fanMode) == nil {
            let m = BackendService.string(fan, "mode") ?? BackendService.string(fan, "actual") ?? "normal"
            d.set(["normal", "custom", "curve"].contains(m) ? m : "normal", forKey: K.fanMode)
        }
        if let lv = BackendService.int(fan, "actual_level"), d.object(forKey: K.fanLevel) == nil {
            d.set(lv, forKey: K.fanLevel)
        }
        if let misc = fan["misc"] as? [String: Any] {
            func seedBool(_ k: String, _ src: String) {
                if d.object(forKey: k) == nil, let v = BackendService.bool(misc, src) { d.set(v, forKey: k) }
            }
            seedBool(K.kbBacklight, "keyboard_backlight")
            seedBool(K.winLock, "win_lock")
            seedBool(K.osd, "osd")
            seedBool(K.silentMode, "silent_mode")
            seedBool(K.passiveCooling, "passive_cooling_disabled")
            seedBool(K.fnLock, "fn_lock")
        }
    }

    /// 灯效页的海岸灯模式也一样：首次从 EC 播种，之后用记忆
    @MainActor
    static func seedLightbarIfNeeded(_ lightbar: [String: Any]) {
        guard (lightbar["available"] as? Bool) == true else { return }
        if d.string(forKey: K.lightbarMode) == nil,
           let m = BackendService.string(lightbar, "mode") {
            d.set(m, forKey: K.lightbarMode)
        }
        if d.string(forKey: K.lightbarHex) == nil,
           let hex = BackendService.string(lightbar, "hex") {
            d.set(hex, forKey: K.lightbarHex)
        }
    }


    /// 启动对账（2.8.11，用户要求）
    ///
    /// 规则：**除「散热模式 / 系统功耗设置」以外**的项 —— 初始化时比一次 EC 与记忆，
    /// 不一致就以记忆为准，把记忆值写回 EC（让硬件回到用户上次的设置）。
    /// 散热/功耗两项故意排除：它们是同一个字节 0x7AB 的高低半字节，原厂语义是
    /// 「动功耗 → 散热跟随；只动散热 → 功耗不动」，必须始终显示 EC 真值。
    ///
    /// 返回需要下发到 `/api/fan` 的 (参数名, 值) 列表；每次启动只算一次。
    @MainActor
    static func mismatches(_ fan: [String: Any]) -> [(String, Any)] {
        guard !reconciled, !fan.isEmpty else { return [] }
        reconciled = true

        var out: [(String, Any)] = []
        if let misc = fan["misc"] as? [String: Any] {
            func cmp(_ prefKey: String, _ fanKey: String) {
                guard let want = d.object(forKey: prefKey) as? Bool,
                      let cur = BackendService.bool(misc, fanKey), want != cur else { return }
                out.append((fanKey, want))
            }
            cmp(K.kbBacklight, "keyboard_backlight")
            cmp(K.winLock, "win_lock")
            cmp(K.osd, "osd")
            cmp(K.silentMode, "silent_mode")
            cmp(K.passiveCooling, "passive_cooling_disabled")
            cmp(K.fnLock, "fn_lock")
        }
        if let want = int(K.charge), let cur = BackendService.int(fan, "charge"), want != cur {
            out.append(("charge", want))
        }
        return out
    }

    private static var reconciled = false

    /// 调试用：把记忆清空，下次启动重新从 EC 播种
    static func resetAll() {
        for k in [K.thermal, K.perfIndex, K.benchmark, K.charge, K.kbBacklight,
                  K.winLock, K.osd, K.silentMode, K.passiveCooling,
                  K.fanMode, K.fanLevel, K.fnLock, K.lightbarMode, K.lightbarHex] {
            d.removeObject(forKey: k)
        }
        seeded = false
        reconciled = false
    }
}
