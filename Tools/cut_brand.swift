// ============================================================================
// cut_brand.swift —— 从品牌图版（brand-sheet.jpg）切出可用素材
//
// 图版布局：左半 LIGHT MODE、右半 DARK MODE，每半从上到下四行：
//   APP ICON / MENU BAR ICON / HORIZONTAL LOCKUP / WORDMARK
//
// 产物（写入 <项目根>/brand/）：
//   appicon-light.png / appicon-dark.png    方形裁切（保留底色，供文档/网页用；
//                                           AppIcon.icns 已有，无需替换）
//   menubar-S.png        18px 黑色（template 用，macOS 自适应深浅色）
//   menubar-S@2x.png     36px 黑色
//   menubar-S@3x.png     54px 黑色（备用）
//   menubar-S-white*.png 白色版（不用 template 机制时手工切）
//   wordmark-light/dark.png   「Sky CC」字标，透明底
//   lockup-light/dark.png     图标+字标横排组合，透明底
//
// 抠底原理：每个区域四角取中位色当背景模型，逐像素算与背景的色差，
// 色差爬坡成 alpha（软阈值），保留柔和阴影为半透明；再按 alpha 包络裁边。
//
// 用法：swift Tools/cut_brand.swift <项目根目录>
// ============================================================================

import AppKit

guard CommandLine.arguments.count >= 2 else {
    print("用法: swift cut_brand.swift <项目根目录>")
    exit(1)
}
let root = CommandLine.arguments[1]
let imgPath = root + "/brand/brand-sheet.jpg"
let outDir = root + "/brand"

guard let img = NSImage(contentsOfFile: imgPath),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("读图失败: \(imgPath)"); exit(1)
}
let rep = NSBitmapImageRep(cgImage: cg)
guard let buf = rep.bitmapData, rep.bitsPerPixel >= 24 else {
    print("取像素数据失败"); exit(1)
}
let W = cg.width, H = cg.height
let Wd = Double(W), Hd = Double(H)
let bpp = rep.bitsPerPixel / 8
let bpr = rep.bytesPerRow

func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let o = y * bpr + x * bpp
    return (Int(buf[o]), Int(buf[o+1]), Int(buf[o+2]))
}

struct Region {
    let name: String
    let rx, ry, rw, rh: Double   // 归一化区域
    let keyed: Bool              // true=透明底（色差键控）；false=原样方形裁切
    let t0: Double, t1: Double
}

func R(_ n: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
       _ keyed: Bool, _ t0: Double, _ t1: Double) -> Region {
    Region(name: n, rx: x, ry: y, rw: w, rh: h, keyed: keyed, t0: t0, t1: t1)
}

let regions: [Region] = [
    // 左半（浅色）：图标卡与底都是浅色，阈值要低才不至于把白卡抠穿
    R("appicon-light", 0.125, 0.132, 0.245, 0.212, false, 8, 20),
    R("menubar-light", 0.246, 0.446, 0.110, 0.098, true,  14, 60),   // 只取大 glyph，避开标题/参考线
    R("wordmark-light",0.04,  0.833, 0.44,  0.105, true,  9,  26),
    // 右半（深色）
    R("appicon-dark",  0.625, 0.132, 0.245, 0.212, false, 8, 20),
    R("menubar-dark",  0.745, 0.446, 0.115, 0.098, true,  14, 60),
    R("wordmark-dark", 0.54,  0.833, 0.44,  0.105, true,  19, 38),
]

/// 3×3 中值滤波：去孤立噪点（JPEG 伪影），字母笔画厚不受影响
func median3x3(_ a: [UInt8], _ rw: Int, _ rh: Int) -> [UInt8] {
    var out = a
    for y in 0..<rh { for x in 0..<rw {
        var vals: [Int] = []
        for dy in -1...1 { for dx in -1...1 {
            let xx = min(max(x + dx, 0), rw - 1), yy = min(max(y + dy, 0), rh - 1)
            vals.append(Int(a[yy * rw + xx]))
        } }
        vals.sort()
        out[y * rw + x] = UInt8(vals[4])
    } }
    return out
}

/// 清除图版的辅助参考线：整行/整列都是高 alpha 的细带（厚度≤4px）。
/// 字母笔画厚、有纵向延续；参考线薄、孤立 —— 用「邻居也有 alpha」区分。
func cleanThinLines(_ alphaMap: [UInt8], _ rw: Int, _ rh: Int) -> [UInt8] {
    var a = alphaMap
    let strong: (Int, Int) -> Bool = { x, y in
        x >= 0 && x < rw && y >= 0 && y < rh && a[y * rw + x] > 128
    }
    // 横向细线：一整行 >75% 高 alpha；支撑只在 5…14px 外找（近邻会自我支撑）
    for y in 0..<rh {
        var cnt = 0
        for x in 0..<rw where a[y * rw + x] > 128 { cnt += 1 }
        if cnt > rw / 2 {
            for x in 0..<rw {
                var supported = false
                for dy in [-14, -12, -10, -8, -7, -6, -5, 5, 6, 7, 8, 10, 12, 14] {
                    if strong(x, y + dy) { supported = true }
                }
                if !supported { a[y * rw + x] = 0 }
            }
        }
    }
    // 纵向细线：一整列 >75% 高 alpha
    for x in 0..<rw {
        var cnt = 0
        for y in 0..<rh where a[y * rw + x] > 128 { cnt += 1 }
        if cnt > rh / 2 {
            for y in 0..<rh {
                var supported = false
                for dx in [-14, -12, -10, -8, -7, -6, -5, 5, 6, 7, 8, 10, 12, 14] {
                    if strong(x + dx, y) { supported = true }
                }
                if !supported { a[y * rw + x] = 0 }
            }
        }
    }
    return a
}

/// 区域内四角各取 8×8 的中位色当背景（JPEG 噪声下比均值稳）；坐标为像素 Double
func bgColor(_ rx: Double, _ ry: Double, _ rw2: Double, _ rh2: Double) -> (Int, Int, Int) {
    func patchMedian(_ cx: Int, _ cy: Int) -> [Int] {
        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        for dy in -4...4 { for dx in -4...4 {
            let p = px(min(max(cx+dx, 0), W-1), min(max(cy+dy, 0), H-1))
            rs.append(p.0); gs.append(p.1); bs.append(p.2)
        } }
        func med(_ a: [Int]) -> Int { a.sorted()[a.count/2] }
        return [med(rs), med(gs), med(bs)]
    }
    let xs = [Int(rx + 6), Int(rx + rw2 - 6)], ys = [Int(ry + 6), Int(ry + rh2 - 6)]
    var all: [[Int]] = []
    for x in xs { for y in ys { all.append(patchMedian(x, y)) } }
    // 四角里取「彼此最接近的三个」的中位，防某个角落在内容上
    func dist(_ a: [Int], _ b: [Int]) -> Int {
        abs(a[0]-b[0]) + abs(a[1]-b[1]) + abs(a[2]-b[2])
    }
    let anchor = all[0]
    all.sort { dist($0, anchor) < dist($1, anchor) }
    var m = [0, 0, 0]
    for i in 0..<3 { for c in 0..<3 { m[c] += all[i][c] } }
    return (m[0]/3, m[1]/3, m[2]/3)
}

/// 对区域做键控/裁切，返回裁边后的 RGBA rep
func cut(_ reg: Region) -> NSBitmapImageRep? {
    let x0d = reg.rx * Wd, y0d = reg.ry * Hd
    let rwd = reg.rw * Wd, rhd = reg.rh * Hd
    let bg = bgColor(x0d, y0d, rwd, rhd)
    let x0 = Int(x0d), y0 = Int(y0d)
    let rw = Int(rwd), rh = Int(rhd)

    // alpha 包络 + 内容包围盒
    var minX = rw, minY = rh, maxX = -1, maxY = -1
    var alphaMap = [UInt8](repeating: 0, count: rw * rh)
    let t0 = reg.t0, t1 = reg.t1, span = reg.t1 - reg.t0
    for ly in 0..<rh {
        for lx in 0..<rw {
            let p = px(x0 + lx, y0 + ly)
            let d = max(abs(p.0 - bg.0), max(abs(p.1 - bg.1), abs(p.2 - bg.2)))
            let dd = Double(d)
            var a = 0
            if dd >= t1 {
                a = 255
            } else if dd > t0 {
                a = Int((dd - t0) / span * 255.0)
            }
            alphaMap[ly * rw + lx] = UInt8(a)
            if a > 128 {
                minX = min(minX, lx); maxX = max(maxX, lx)
                minY = min(minY, ly); maxY = max(maxY, ly)
            }
        }
    }
    guard maxX > minX, maxY > minY else { print("  !! \(reg.name) 区域没找到内容"); return nil }
    if reg.keyed {
        alphaMap = cleanThinLines(alphaMap, rw, rh)
        alphaMap = median3x3(median3x3(alphaMap, rw, rh), rw, rh)
        // 参考线清掉后重算包围盒
        minX = rw; minY = rh; maxX = -1; maxY = -1
        for ly in 0..<rh { for lx in 0..<rw where alphaMap[ly * rw + lx] > 128 {
            minX = min(minX, lx); maxX = max(maxX, lx)
            minY = min(minY, ly); maxY = max(maxY, ly)
        } }
        guard maxX > minX, maxY > minY else { print("  !! \(reg.name) 清线后无内容"); return nil }
        // lockup：卡片区域不在这一步强行提升 —— 卡片与附近参考线难分离，
        // 统一交给后面的合成后处理（用 appicon 切片贴回圆角卡片）
    }
    let cw0 = maxX - minX + 1, ch0 = maxY - minY + 1
    var cw = cw0, ch = ch0, ox = 0, oy = 0
    if !reg.keyed {
        // app 图标：参考线紧贴卡片边。擦线时近邻（±4px 内）不算支撑，
        // 否则线自身的像素会「自我支撑」导致擦不掉；只在 5…14px 外找内容
        func eraseLinesH(_ map: [UInt8]) {
            for ly in 0..<rh {
                var cnt = 0
                for lx in 0..<rw where map[ly * rw + lx] > 128 { cnt += 1 }
                if cnt > rw * 3 / 5 {
                    for lx in 0..<rw {
                        var supported = false
                        for dy in [-14, -12, -10, -8, -7, -6, -5, 5, 6, 7, 8, 10, 12, 14] {
                            let yy = ly + dy
                            if yy >= 0 && yy < rh && map[yy * rw + lx] > 128 { supported = true }
                        }
                        if !supported {
                            let o = (y0 + ly) * bpr + (x0 + lx) * bpp
                            buf[o] = UInt8(bg.0); buf[o+1] = UInt8(bg.1); buf[o+2] = UInt8(bg.2)
                        }
                    }
                }
            }
        }
        var diffMap = [UInt8](repeating: 0, count: rw * rh)
        for ly in 0..<rh { for lx in 0..<rw {
            let p = px(x0 + lx, y0 + ly)
            let d = max(abs(p.0 - bg.0), max(abs(p.1 - bg.1), abs(p.2 - bg.2)))
            diffMap[ly * rw + lx] = d > 8 ? 255 : 0
        } }
        eraseLinesH(diffMap)
        // 纵向参考线：转置处理（列覆盖 >60% 且 5…14px 外无内容）
        for lx in 0..<rw {
            var cnt = 0
            for ly in 0..<rh where diffMap[ly * rw + lx] > 128 { cnt += 1 }
            if cnt > rh * 3 / 5 {
                for ly in 0..<rh {
                    var supported = false
                    for dx in [-14, -12, -10, -8, -7, -6, -5, 5, 6, 7, 8, 10, 12, 14] {
                        let xx = lx + dx
                        if xx >= 0 && xx < rw && diffMap[ly * rw + xx] > 128 { supported = true }
                    }
                    if !supported {
                        let o = (y0 + ly) * bpr + (x0 + lx) * bpp
                        buf[o] = UInt8(bg.0); buf[o+1] = UInt8(bg.1); buf[o+2] = UInt8(bg.2)
                    }
                }
            }
        }
    }

    let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: cw, height: ch)
    let ob = out.bitmapData!
    for ly in 0..<ch {
        for lx in 0..<cw {
            let sx = x0 + minX + ox + lx, sy = y0 + minY + oy + ly
            let p = px(sx, sy)
            let a = reg.keyed ? alphaMap[(minY + oy + ly) * rw + (minX + ox + lx)] : 255
            let o = ly * out.bytesPerRow + lx * 4
            ob[o] = UInt8(p.0); ob[o+1] = UInt8(p.1); ob[o+2] = UInt8(p.2); ob[o+3] = UInt8(a)
        }
    }
    return out
}

func scale(_ src: NSBitmapImageRep, toHeight h: Int) -> NSBitmapImageRep {
    let sw = src.pixelsWide, sh = src.pixelsHigh
    let nw = max(1, sw * h / sh)
    let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: nw, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: nw, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let ns = NSImage(cgImage: src.cgImage!, size: NSSize(width: sw, height: sh))
    ns.draw(in: NSRect(x: 0, y: 0, width: nw, height: h),
            from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return out
}

func savePNG(_ out: NSBitmapImageRep, to path: String) {
    let png = out.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("  → \(path)  \(out.pixelsWide)×\(out.pixelsHigh)")
}

print("切图（\(W)×\(H) 源图）：")
var cuts: [String: NSBitmapImageRep] = [:]
for reg in regions {
    print("· \(reg.name)")
    guard let out = cut(reg) else { continue }
    cuts[reg.name] = out
    savePNG(out, to: outDir + "/\(reg.name).png")
}

// ----------------------------------------------------------------------------
// lockup 合成：不再从图版抠小图标卡（白卡与浅底色差太小、残线难除），直接
// 用已切好的 appicon（中心 84% = 卡片本体）+ wordmark 程序化合成：
//   · 卡片高 = 字标高，圆角 22%
//   · 图标与字标间距 = 字标高的 18%
//   · 字标垂直居中
// ----------------------------------------------------------------------------
func roundedCard(from icon: NSBitmapImageRep, side: Int) -> NSBitmapImageRep? {
    let iconSide = Int(Double(icon.pixelsWide) * 0.84)
    let off = (icon.pixelsWide - iconSide) / 2
    guard let cg = icon.cgImage?
        .cropping(to: CGRect(x: off, y: off, width: iconSide, height: iconSide))
    else { return nil }
    let card = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    card.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: card)
    let img = NSImage(cgImage: cg, size: NSSize(width: iconSide, height: iconSide))
    img.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
             from: .zero, operation: .copy, fraction: 1)
    let radius = CGFloat(Double(side) * 0.22)
    let ring = NSBezierPath()
    ring.appendRect(NSRect(x: 0, y: 0, width: side, height: side))
    ring.appendRoundedRect(NSRect(x: 0, y: 0, width: side, height: side),
                           xRadius: radius, yRadius: radius)
    ring.windingRule = .evenOdd
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    ring.fill()
    NSGraphicsContext.restoreGraphicsState()
    return card
}

func composeLockup(icon: NSBitmapImageRep, wordmark: NSBitmapImageRep) -> NSBitmapImageRep {
    let side = wordmark.pixelsHigh
    let gap = Int(Double(side) * 0.18)
    let lw = side + gap + wordmark.pixelsWide
    let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: lw, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: lw, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    if let card = roundedCard(from: icon, side: side) {
        let ci = NSImage(cgImage: card.cgImage!, size: NSSize(width: side, height: side))
        ci.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                from: .zero, operation: .copy, fraction: 1)
    }
    let wmH = wordmark.pixelsHigh
    let wmY = (side - wmH) / 2
    let wi = NSImage(cgImage: wordmark.cgImage!, size: NSSize(width: wordmark.pixelsWide, height: wmH))
    wi.draw(in: NSRect(x: side + gap, y: wmY, width: wordmark.pixelsWide, height: wmH),
            from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return out
}

for (lk, ic, wm) in [("lockup-light", "appicon-light", "wordmark-light"),
                     ("lockup-dark",  "appicon-dark",  "wordmark-dark")] {
    if let icon = cuts[ic], let wm = cuts[wm] {
        savePNG(composeLockup(icon: icon, wordmark: wm), to: outDir + "/\(lk).png")
    }
}


// 菜单栏图标：黑色版按 macOS template 规范出 1x/2x/3x（系统自动适配深浅色），
// 白色版整组备用
if let black = cuts["menubar-light"] {
    for (suffix, h) in [("", 18), ("@2x", 36), ("@3x", 54)] {
        savePNG(scale(black, toHeight: h), to: outDir + "/menubar-S\(suffix).png")
    }
}
if let white = cuts["menubar-dark"] {
    for (suffix, h) in [("", 18), ("@2x", 36)] {
        savePNG(scale(white, toHeight: h), to: outDir + "/menubar-S-white\(suffix).png")
    }
}
print("完成。")
