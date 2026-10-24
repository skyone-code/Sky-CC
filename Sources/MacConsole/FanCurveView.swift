import SwiftUI

/// 可拖拽的风扇曲线图：拖动点改（温度,档位），空白处单击加点。
/// 所有坐标换算在图形像素空间内完成；全区域手势负责"拾取最近点 / 空白加点"。
struct FanCurveGraph: View {
    @Binding var points: [FanCurvePoint]
    @State private var draggingID: UUID? = nil

    private let tempMin = FanCurveConfig.tempMin
    private let tempMax = FanCurveConfig.tempMax
    private let levelMax = FanCurveConfig.levelMax

    private func x(_ t: Int, _ w: CGFloat) -> CGFloat {
        CGFloat(t - tempMin) / CGFloat(tempMax - tempMin) * w
    }
    private func y(_ l: Int, _ h: CGFloat) -> CGFloat {
        h - CGFloat(l) / CGFloat(levelMax) * h
    }
    private func tempAt(_ px: CGFloat, _ w: CGFloat) -> Int {
        Int((px / w * CGFloat(tempMax - tempMin) + CGFloat(tempMin)).rounded())
    }
    private func levelAt(_ py: CGFloat, _ h: CGFloat) -> Int {
        Int(((h - py) / h * CGFloat(levelMax)).rounded())
    }

    var body: some View {
        GeometryReader { geo in
            graphContent(w: geo.size.width, h: geo.size.height)
        }
        .frame(height: 190)
    }

    // 拆成多个小函数：避免单个巨型 body 表达式触发 Swift 类型检查器超时
    // （超时会在无关文件上甩出虚假的「cannot find in scope」并报整编失败）。
    private func graphContent(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            background()
            horizontalGrid(w: w, h: h)
            verticalGrid(w: w, h: h)
            curveLayer(w: w, h: h)
            controlPoints(w: w, h: h)
            gestureLayer(w: w, h: h)
        }
    }

    private func background() -> some View {
        RoundedRectangle(cornerRadius: 8).fill(Theme.panel2)
    }

    private func horizontalGrid(w: CGFloat, h: CGFloat) -> some View {
        ForEach(0...levelMax, id: \.self) { lv in
            Path { p in
                let yy = y(lv, h)
                p.move(to: CGPoint(x: 0, y: yy))
                p.addLine(to: CGPoint(x: w, y: yy))
            }
            .stroke(Theme.line.opacity(0.5), lineWidth: 0.5)
        }
    }

    private func verticalGrid(w: CGFloat, h: CGFloat) -> some View {
        ForEach(Array(stride(from: tempMin, through: tempMax, by: 10)), id: \.self) { t in
            Path { p in
                let xx = x(t, w)
                p.move(to: CGPoint(x: xx, y: 0))
                p.addLine(to: CGPoint(x: xx, y: h))
            }
            .stroke(Theme.line.opacity(0.5), lineWidth: 0.5)
        }
    }

    private func curveLayer(w: CGFloat, h: CGFloat) -> some View {
        let sp = points.sorted { $0.temp < $1.temp }
        return Path { p in
            guard !sp.isEmpty else { return }
            p.move(to: CGPoint(x: x(sp[0].temp, w), y: y(sp[0].level, h)))
            for pt in sp.dropFirst() {
                p.addLine(to: CGPoint(x: x(pt.temp, w), y: y(pt.level, h)))
            }
        }
        .stroke(Theme.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func controlPoints(w: CGFloat, h: CGFloat) -> some View {
        ForEach(points) { pt in
            let px = x(pt.temp, w), py = y(pt.level, h)
            Circle()
                .fill(draggingID == pt.id ? Theme.red : Theme.blue)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .position(x: px, y: py)
            Text("L\(pt.level)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.dim)
                .position(x: px, y: py - 16)
        }
    }

    private func gestureLayer(w: CGFloat, h: CGFloat) -> some View {
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if draggingID == nil {
                        var best: UUID? = nil
                        var bestD = CGFloat(22)
                        for p in points {
                            let dx = x(p.temp, w) - g.startLocation.x
                            let dy = y(p.level, h) - g.startLocation.y
                            let d = sqrt(dx * dx + dy * dy)
                            if d < bestD { bestD = d; best = p.id }
                        }
                        if let id = best { draggingID = id }
                    }
                    if let id = draggingID,
                       let idx = points.firstIndex(where: { $0.id == id }) {
                        let t = min(tempMax, max(tempMin, tempAt(g.location.x, w)))
                        let l = min(levelMax, max(0, levelAt(g.location.y, h)))
                        points[idx] = FanCurvePoint(id: id, temp: t, level: l)
                    }
                }
                .onEnded { g in
                    if draggingID != nil {
                        draggingID = nil
                        points.sort { $0.temp < $1.temp }
                    } else if sqrt(g.translation.width * g.translation.width
                                  + g.translation.height * g.translation.height) < 8 {
                        let t = min(tempMax, max(tempMin, tempAt(g.location.x, w)))
                        let l = min(levelMax, max(0, levelAt(g.location.y, h)))
                        if !points.contains(where: {
                            abs($0.temp - t) < 3 && abs($0.level - l) < 1
                        }) {
                            points.append(FanCurvePoint(temp: t, level: l))
                            points.sort { $0.temp < $1.temp }
                        }
                    }
                }
            )
    }
}

/// 风扇曲线编辑器：温度源 + 可拖拽图 + 点列表（滑块精调/删除）+ 实时读数。
///
/// v2.5.3.1 交互改版（用户需求：「按了确定才会发送当前的曲线模式设置」）：
/// 编辑全部落在本地草稿 draft 上（只做防丢落盘，不发送、不激活）；
/// 点「应用曲线」才把 draft 提交给控制器（ctrl.config = draft）并 POST
/// mode=curve 激活。曲线运行中改草稿时控制器继续按旧配置跑，确认后切换。
struct FanCurveView: View {
    @EnvironmentObject var backend: BackendService
    @EnvironmentObject var store: MonitorStore
    /// 本地草稿：进入页面时从磁盘上的运行配置拷贝，所有编辑只改它
    @State private var draft: FanCurveConfig = FanCurveStore.load() ?? .default
    /// 草稿相对运行配置有未应用改动
    @State private var dirty = false
    /// 应用结果提示（替代 toast，编辑器内自足）
    @State private var note: String?

    // 2.6.0：曲线守护搬进后台 helper（UI 退出也要继续调速），所以这里不再持有
    // FanCurveController，实时状态一律读 helper 通过 /api/fan 回报的 curve 快照。
    private var curveSnap: [String: Any] { BackendService.dict(store.fan, "curve") ?? [:] }
    private var ctrlActive: Bool { (curveSnap["active"] as? Bool) ?? false }
    private var ctrlTemp: Int { (curveSnap["current_temp"] as? NSNumber)?.intValue ?? 0 }
    private var ctrlLevel: Int { (curveSnap["current_level"] as? NSNumber)?.intValue ?? 0 }

    /// 运行中的曲线配置：优先用 helper 回报的值，拿不到就退回磁盘上最后一次编辑
    private var ctrlConfig: FanCurveConfig {
        var c = FanCurveStore.load() ?? .default
        if let src = curveSnap["source"] as? String { c.source = src }
        if let fs = (curveSnap["failsafe_temp"] as? NSNumber)?.intValue { c.failsafeTemp = fs }
        if let pts = curveSnap["points"] as? [[String: Any]] {
            let parsed: [FanCurvePoint] = pts.compactMap { d in
                guard let t = (d["temp"] as? NSNumber)?.intValue,
                      let l = (d["level"] as? NSNumber)?.intValue else { return nil }
                return FanCurvePoint(temp: t, level: l)
            }
            if parsed.count >= 2 { c.points = parsed }
        }
        return c
    }

    private let tempMin = FanCurveConfig.tempMin
    private let tempMax = FanCurveConfig.tempMax

    /// 防丢：编辑只落盘（重启后恢复到最后编辑状态），不发送、不激活。
    /// 真正的「发送 + 激活」只在 applyDraft()（应用曲线按钮）发生。
    private func persistDraftLocal() {
        FanCurveStore.save(draft)
    }

    /// 提交草稿：更新运行配置 + 落盘 + POST 激活（用户点「应用曲线」才走到这）
    private func applyDraft() async {
        // 不再写本进程的控制器：helper 收到 mode=curve 后会更新自己的配置并落盘
        FanCurveStore.save(draft)
        let r = await backend.post("/api/fan", curveBody(draft))
        dirty = false
        if r["ok"] as? Bool == true {
            note = "已应用：曲线模式已激活，随温度自动调速"
        } else {
            note = "应用失败：\(BackendService.string(r, "error") ?? "未知")"
        }
        NotificationCenter.default.post(name: .macConsoleStateChanged, object: nil)
    }

    private func curveBody(_ c: FanCurveConfig) -> [String: Any] {
        ["mode": "curve",
         "source": c.source,
         "failsafe": c.failsafeTemp,
         "points": c.points.map { ["temp": $0.temp, "level": $0.level] }]
    }

    private func tempBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: { draft.points.first(where: { $0.id == id })?.temp ?? 0 },
            set: { v in
                var c = draft
                if let i = c.points.firstIndex(where: { $0.id == id }) { c.points[i].temp = v }
                c.points.sort { $0.temp < $1.temp }
                draft = c
                dirty = true
                persistDraftLocal()
            })
    }
    private func levelBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: { draft.points.first(where: { $0.id == id })?.level ?? 0 },
            set: { v in
                var c = draft
                if let i = c.points.firstIndex(where: { $0.id == id }) { c.points[i].level = v }
                draft = c
                dirty = true
                persistDraftLocal()
            })
    }
    private func tempBindingD(for id: UUID) -> Binding<Double> {
        Binding(get: { Double(tempBinding(for: id).wrappedValue) },
                set: { tempBinding(for: id).wrappedValue = Int($0) })
    }
    private func levelBindingD(for id: UUID) -> Binding<Double> {
        Binding(get: { Double(levelBinding(for: id).wrappedValue) },
                set: { levelBinding(for: id).wrappedValue = Int($0) })
    }

    private func removePoint(_ id: UUID) {
        guard draft.points.count > 2 else { return }
        var c = draft
        c.points.removeAll { $0.id == id }
        draft = c
        dirty = true
        persistDraftLocal()
    }

    private func addPoint() {
        var c = draft
        let sp = c.points.sorted { $0.temp < $1.temp }
        var insertTemp = (tempMin + tempMax) / 2
        var maxGap = -1
        for i in 0..<(sp.count - 1) {
            let gap = sp[i + 1].temp - sp[i].temp
            if gap > maxGap { maxGap = gap; insertTemp = (sp[i].temp + sp[i + 1].temp) / 2 }
        }
        c.points.append(FanCurvePoint(temp: insertTemp, level: c.level(for: insertTemp)))
        c.points.sort { $0.temp < $1.temp }
        draft = c
        dirty = true
        persistDraftLocal()
    }

    private func pointRow(_ pt: FanCurvePoint) -> some View {
        HStack(spacing: 10) {
            Text("\(pt.temp)°C")
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 52, alignment: .leading)
            Slider(value: tempBindingD(for: pt.id), in: Double(tempMin)...Double(tempMax), step: 1)
                .tint(Theme.blue)
            Text("L\(pt.level)")
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 26, alignment: .trailing)
            Slider(value: levelBindingD(for: pt.id), in: 0...7, step: 1)
                .tint(Theme.blue)
                .frame(width: 110)
            Button { removePoint(pt.id) } label: { Image(systemName: "minus.circle") }
                .disabled(ctrlConfig.points.count <= 2)
        }
    }

    private var pointsBinding: Binding<[FanCurvePoint]> {
        Binding(
            get: { draft.points },
            set: { v in
                var c = draft; c.points = v; draft = c
                dirty = true
                persistDraftLocal()
            })
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Text("曲线温度源").font(.system(size: 12)).foregroundStyle(Theme.dim)
            Spacer()
            SegmentedPicker(
                options: [("max", "最大"), ("cpu", "CPU"), ("gpu", "GPU")],
                selection: Binding(
                    get: { draft.source },
                    set: { v in
                        var c = draft; c.source = v; draft = c
                        dirty = true
                        persistDraftLocal()
                    }))
                .frame(width: 230)
        }
    }

    private var statusRow: some View {
        HStack {
            if ctrlActive {
                VStack(alignment: .leading, spacing: 2) {
                    Text("实时：温度 \(ctrlTemp)°C → 档位 L\(ctrlLevel)")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.green)
                    if dirty {
                        Text("曲线运行中（旧配置）—— 有未应用的编辑，点「应用曲线」后生效")
                            .font(.system(size: 10)).foregroundStyle(Theme.amber)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("曲线未激活（编辑后点「应用曲线」启动）")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim2)
                    if dirty {
                        Text("有未应用的编辑").font(.system(size: 10)).foregroundStyle(Theme.amber)
                    }
                }
            }
            Spacer()
            Button { addPoint() } label: { Image(systemName: "plus.circle") }
                .controlSize(.small)
                .help("在最大间隔处插入一个点")
        }
    }

    /// 草稿操作栏：还原 / 应用（v2.5.3.1 确定按钮）
    private var applyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("还原") {
                    draft = ctrlConfig
                    dirty = false
                    note = nil
                }
                .disabled(!dirty)
                Spacer()
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(note.hasPrefix("应用失败") ? Theme.red : Theme.green)
                }
                Button {
                    Task { await applyDraft() }
                } label: {
                    Text(dirty ? "应用曲线" : "已同步")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .disabled(!dirty)
            }
            Text("编辑只改本地草稿（自动保存防丢）；点「应用曲线」才写入 EC 并激活曲线模式。低于首点温度保持最低档，高于末点保持最高档；≥\(draft.failsafeTemp)°C 强制全速。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim2)
                .cardNote()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceRow
            FanCurveGraph(points: pointsBinding)
            statusRow
            ForEach(draft.points) { pt in
                pointRow(pt)
            }
            applyBar
        }
        // 页面出现时同步运行配置；有未应用编辑时不覆盖（防丢）
        .onAppear {
            if !dirty {
                draft = ctrlConfig
                note = nil
            }
        }
    }
}
