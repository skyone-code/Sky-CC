//
//  BrandAssets.swift
//  Sky CC —— 品牌图预缩放缓存
//
//  2026-11-18 锯齿修复（用户反馈「所有 logo 都是锯齿状」）：
//  交付的 lockup 母版 1644×640、主图标母版 1464×1483，界面里直接
//  `.resizable().interpolation(.high)` 缩到 44~86pt，压缩比 10~30×。
//  单步大比例缩放哪怕高插值也是 bilinear 一类，必然出阶梯。
//  这里做多级减半（mip 链）：每级 2× 用高质量插值重采样，压到接近
//  目标尺寸后再交给界面做小幅缩放，阶梯消失。结果按「名字+目标高」缓存。
//

import AppKit

enum BrandAssets {

    static let cache = NSCache<NSString, NSImage>()

    /// 把打包进 Resources 的品牌图预缩放到「目标像素高」（给 2× retina 用，
    /// 调用方传 pt 高 × 2）。返回的 NSImage 尺寸即目标尺寸，界面只需 ≤2× 缩放。
    static func prescaled(_ resourceName: String, ext: String = "png",
                          targetPixelHeight: Int) -> NSImage? {
        let key = "\(resourceName).\(ext)#\(targetPixelHeight)" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext),
              let src = NSImage(contentsOf: url),
              let tiff = src.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }

        var img = src
        var h = rep.pixelsHigh
        // 先按 2× 减半逼近（1464 → 732 → 366 → 183…），每步都是温和的 2× 重采样
        while h > targetPixelHeight * 2 {
            let half = NSSize(width: max(1, rep.pixelsWide / 2), height: max(1, h / 2))
            img = render(img, toSize: half)
            h = Int(half.height)
        }
        // 末级：精确到目标像素高（保持纵横比）
        let w = Int((Double(rep.pixelsWide) / Double(rep.pixelsHigh)) * Double(targetPixelHeight))
        let final = render(img, toSize: NSSize(width: max(1, w), height: targetPixelHeight))
        cache.setObject(final, forKey: key)
        return final
    }

    /// 高质量重采样到指定尺寸（带 alpha）
    private static func render(_ img: NSImage, toSize size: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        img.draw(in: NSRect(origin: .zero, size: size),
                 from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }
}
