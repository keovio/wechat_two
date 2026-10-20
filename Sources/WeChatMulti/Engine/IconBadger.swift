import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 给实例图标叠一个编号角标，让 Dock / 启动台 / 应用切换器里一眼分清「微信 1」「微信 2」。
///
/// 做法：取官方微信的图标 → 每个尺寸画一枚红色圆形数字角标 → 写成新的 .icns，
/// 再把 Info.plist 的 CFBundleIconFile 指向它，并移除 CFBundleIconName
/// （否则系统优先用 Assets.car 里的原图标，角标不生效）。
///
/// ★ 必须在重签**之前**执行：Resources 下的文件受签名封印保护。
enum IconBadger {
    static let iconFileName = "WeChatMultiIcon"
    private static let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]

    static func apply(app: URL, sourceApp: URL, label: String) throws {
        let base = NSWorkspace.shared.icon(forFile: sourceApp.path)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let out = resources.appendingPathComponent(iconFileName + ".icns")

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL,
                                                         UTType.icns.identifier as CFString,
                                                         pixelSizes.count, nil) else {
            throw BadgeError.writeFailed(out.path)
        }
        for px in pixelSizes {
            guard let image = render(base: base, label: label, px: px) else { throw BadgeError.renderFailed(px) }
            CGImageDestinationAddImage(dest, image, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw BadgeError.writeFailed(out.path) }

        try IdentityRewriter.mutatePlist(app.appendingPathComponent("Contents/Info.plist")) { dict in
            dict["CFBundleIconFile"] = iconFileName
            dict.removeValue(forKey: "CFBundleIconName")
        }
    }

    /// 纯 CoreGraphics 绘制，可在后台线程调用（不依赖 NSImage.lockFocus）。
    static func render(base: NSImage, label: String, px: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let s = CGFloat(px)
        let canvas = CGRect(x: 0, y: 0, width: s, height: s)

        var proposed = canvas
        if let cg = base.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: canvas)
        }

        // 右上角圆形角标（CG 坐标原点在左下）。
        let d = s * 0.44
        let inset = s * 0.03
        let badge = CGRect(x: s - d - inset, y: s - d - inset, width: d, height: d)
        ctx.setFillColor(CGColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1))
        ctx.fillEllipse(in: badge)
        if px >= 32 {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(max(1, s * 0.02))
            ctx.strokeEllipse(in: badge.insetBy(dx: s * 0.01, dy: s * 0.01))
        }

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let fontSize = d * (label.count > 1 ? 0.48 : 0.62)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: label, attributes: attrs)
        let size = text.size()
        text.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    enum BadgeError: Error, LocalizedError {
        case renderFailed(Int)
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .renderFailed(let px): return "绘制 \(px)px 图标失败"
            case .writeFailed(let p): return "写入图标失败：\(p)"
            }
        }
    }
}
