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
        let fm = FileManager.default
        let base = NSWorkspace.shared.icon(forFile: sourceApp.path)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let out = resources.appendingPathComponent(iconFileName + ".icns")

        // 用系统 iconutil 从标准 .iconset 生成 icns —— 比 ImageIO 直接写 ICNS 可靠（后者对部分尺寸静默失败）。
        let iconset = fm.temporaryDirectory
            .appendingPathComponent("wechatmulti-" + UUID().uuidString + ".iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconset) }

        let entries: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in entries {
            guard let image = render(base: base, label: label, px: px) else { throw BadgeError.renderFailed(px) }
            try writePNG(image, to: iconset.appendingPathComponent(name + ".png"))
        }

        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try Shell.run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", out.path])
        guard fm.fileExists(atPath: out.path) else { throw BadgeError.writeFailed(out.path) }

        try IdentityRewriter.mutatePlist(app.appendingPathComponent("Contents/Info.plist")) { dict in
            dict["CFBundleIconFile"] = iconFileName
            dict.removeValue(forKey: "CFBundleIconName")
        }
        Log.info("角标图标已写入 " + out.path)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BadgeError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw BadgeError.writeFailed(url.path) }
    }

    /// 让 Finder / Dock 丢掉旧图标缓存：touch 包目录 + 重新登记 + 重启 Dock（Dock 会在一秒内自动回来）。
    static func flushIconCache(app: URL) {
        _ = try? Shell.run("/usr/bin/touch", [app.path], allowFailure: true)
        _ = try? Shell.run("/usr/bin/touch", [app.appendingPathComponent("Contents/Info.plist").path], allowFailure: true)
        _ = try? Shell.run("/usr/bin/killall", ["Dock"], allowFailure: true)
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

    // MARK: - 菜单栏（状态栏）小图标

    /// 微信自己在系统菜单栏画的小图标也一样，多开后分不清。
    /// 构建时扫描包内名字含 status / menubar / tray 的小尺寸 PNG/TIFF，
    /// 在右下角挖出一个带编号的实心圆（对模板图和彩色图都有效）。
    /// 返回改写的文件数；放在 Assets.car 里的图标改不到，日志会记下来。
    @discardableResult
    static func badgeStatusIcons(app: URL, label: String) -> Int {
        let fm = FileManager.default
        let pattern = try! NSRegularExpression(pattern: "(status|menubar|menu_bar|tray)", options: [.caseInsensitive])
        let exts: Set<String> = ["png", "tiff", "tif"]
        guard let walker = fm.enumerator(at: app.appendingPathComponent("Contents"),
                                         includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var changed = 0
        for case let url as URL in walker {
            guard exts.contains(url.pathExtension.lowercased()) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { continue }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  img.width <= 256, img.height <= 256,
                  let type = CGImageSourceGetType(src),
                  let out = stampStatus(img, label: label) else { continue }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, out, nil)
            if CGImageDestinationFinalize(dest) {
                changed += 1
                Log.info("菜单栏图标已加编号：" + url.path)
            }
        }
        if changed == 0 {
            Log.warn("没找到可改的菜单栏图标文件（可能在 Assets.car 里）")
        }
        return changed
    }

    private static func stampStatus(_ img: CGImage, label: String) -> CGImage? {
        let w = img.width, h = img.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

        let d = min(W, H) * 0.62
        let circle = CGRect(x: W - d, y: 0, width: d, height: d)   // 右下角
        // 先清出一圈透明描边，再画实心圆，数字用 clear 挖空 —— 模板图渲染成单色时也能看清。
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: circle.insetBy(dx: -d * 0.12, dy: -d * 0.12))
        ctx.setBlendMode(.normal)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillEllipse(in: circle)

        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        ctx.setBlendMode(.clear)
        let font = NSFont.systemFont(ofSize: d * (label.count > 1 ? 0.55 : 0.75), weight: .black)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = text.size()
        text.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
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
