//
//  AllDataView.swift
//  Sky CC —— 「全部信息」页
//
//  为什么要有这一页：/api/all 早就把原生采集到的每个字段都返回了
//  （电池的循环次数/健康度/适配器功率、每核占用、内存分项、statfs 全字段、
//   每块盘的读写计数、每个网卡的地址与速率、SMC 传感器、GPU Statistics…），
//  但仪表盘/监控页只摆了寥寥几张卡片，其余字段等于看不见。
//  这里做的是「不筛选、不隐藏」：递归摊平 store 里的全部数据字典，
//  一组一张卡，可折叠、可搜索、可一键复制原始 JSON。
//

import SwiftUI
import AppKit

struct AllDataView: View {

    @EnvironmentObject private var store: MonitorStore

    @State private var query = ""
    @State private var showRawJSON = false
    @State private var collapsed: Set<String> = ["processes", "disks", "sensors"]

    // MARK: 数据 → 行

    private struct Row: Identifiable {
        let id: String      // 用键路径当 id，天然唯一且稳定
        let key: String
        let text: String
    }

    private struct Card: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    /// 把任意 JSON 值递归摊平成 key.path = value 的行
    private func flatten(_ value: Any, _ prefix: String, _ depth: Int, _ out: inout [Row]) {
        if out.count >= 1200 { return }
        if let dict = value as? [String: Any] {
            if dict.isEmpty {
                out.append(Row(id: prefix, key: prefix, text: "{}"))
                return
            }
            if depth >= 4 {
                out.append(Row(id: prefix, key: prefix, text: "{\(dict.count) 项}"))
                return
            }
            for k in dict.keys.sorted() {
                guard let v = dict[k] else { continue }
                flatten(v, prefix.isEmpty ? k : "\(prefix).\(k)", depth + 1, &out)
            }
            return
        }
        if let arr = value as? [Any] {
            if arr.isEmpty {
                out.append(Row(id: prefix, key: prefix, text: "[]"))
                return
            }
            for (i, v) in arr.enumerated() {
                if let d = v as? [String: Any], !d.isEmpty {
                    for k in d.keys.sorted() {
                        guard let vv = d[k] else { continue }
                        flatten(vv, "\(prefix)[\(i)].\(k)", depth + 1, &out)
                    }
                } else {
                    out.append(Row(id: "\(prefix)[\(i)]", key: "\(prefix)[\(i)]",
                                   text: fmt(v, key: prefix)))
                }
            }
            return
        }
        out.append(Row(id: prefix, key: prefix, text: fmt(value, key: prefix)))
    }

    /// 值格式化：布尔→true/false，字节类数字顺带换算可读单位，其余原样
    private func fmt(_ value: Any, key: String) -> String {
        if value is NSNull { return "—" }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let n = value as? NSNumber {
            let d = n.doubleValue
            var s: String
            if d == d.rounded(), abs(d) < 9.0e15 {
                s = String(n.intValue)
            } else {
                s = String(format: "%.3f", d)
                // 去掉尾部多余的 0，但保留至少一位小数
                while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
            }
            if isByteField(key), abs(d) >= 1024 {
                s += "   (" + humanBytes(d) + ")"
            }
            return s
        }
        if let s = value as? String { return s.isEmpty ? "\"\"" : s }
        return "\(value)"
    }

    /// 键名是否表示「字节数」（只看路径最后一段，避免 AppleRawMaxCapacity 之类误判）
    private func isByteField(_ key: String) -> Bool {
        var leaf = key
        if let r = leaf.range(of: ".", options: .backwards) { leaf = String(leaf[r.upperBound...]) }
        if leaf.contains("[") { leaf = String(leaf.split(separator: "[").first ?? "") }
        let names: Set<String> = [
            "total", "used", "avail", "free", "available", "wired", "active",
            "inactive", "compressed", "purgeable", "speculative", "internal",
            "external", "app", "rss_kb", "vsize_kb", "resident",
        ]
        if names.contains(leaf) { return true }
        return leaf.hasSuffix("_bytes") || leaf.hasSuffix("Bytes") || leaf.hasSuffix("_kb") || leaf.hasSuffix("_kbs")
    }

    private func humanBytes(_ v: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var x = v
        var i = 0
        while abs(x) >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    // MARK: 卡片

    private var cards: [Card] {
        var list: [(String, String, Any)] = [
            ("overview", "系统总览 overview", store.overview),
            ("battery", "电池 battery", store.battery),
            ("fan", "风扇 / EC fan", store.fan),
            ("live", "风扇实时值 fan.live", store.live),
            ("sensors", "SMC 传感器 sensors", store.sensors),
            ("disks", "磁盘 disks", store.disks),
            ("processes", "进程 processes", store.processes),
            ("rgb", "键盘灯效 rgb", store.rgb),
            ("lightbar", "灯条 lightbar", store.lightbar),
            ("volume", "音量 volume", store.volume),
        ]
        list.removeAll { ($0.2 as? [String: Any])?.isEmpty == true || ($0.2 as? [Any])?.isEmpty == true }

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Card] = []
        for (id, title, value) in list {
            var rows: [Row] = []
            flatten(value, "", 0, &rows)
            if !q.isEmpty {
                rows = rows.filter {
                    $0.key.lowercased().contains(q) || $0.text.lowercased().contains(q)
                }
            }
            if rows.isEmpty { continue }
            out.append(Card(id: id, title: title, rows: rows))
        }
        return out
    }

    // MARK: 界面

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if showRawJSON {
                rawJSONView
            } else {
                listView
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索字段名或值（如 cycle、temperature、disk）", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 16)
            Toggle("原始 JSON", isOn: $showRawJSON)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11.5))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawJSON, forType: .string)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.borderless)
            .help("把 /api/all 的全部内容复制成 JSON")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(cards) { card in
                    cardView(card)
                }
                Text("共 \(cards.reduce(0) { $0 + $1.rows.count }) 个字段 · 每 2 秒刷新一次 · 数据来自本机原生接口（IOKit / sysctl / libproc）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func cardView(_ card: Card) -> some View {
        let expanded = Binding(
            get: { !collapsed.contains(card.id) || !self.query.isEmpty },
            set: { isOn in
                if isOn { collapsed.remove(card.id) } else { collapsed.insert(card.id) }
            }
        )
        return DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(card.rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.key)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 250, alignment: .leading)
                        Text(row.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 6)
        } label: {
            HStack(spacing: 8) {
                Text(card.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(card.rows.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private var rawJSON: String {
        let dict: [String: Any] = [
            "overview": store.overview,
            "sensors": store.sensors,
            "battery": store.battery,
            "fan": store.fan,
            "rgb": store.rgb,
            "lightbar": store.lightbar,
            "volume": store.volume,
            "disks": store.disks,
            "processes": store.processes,
        ]
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private var rawJSONView: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(rawJSON)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
        }
    }
}
