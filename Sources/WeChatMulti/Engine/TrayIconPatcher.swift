import AppKit
import Compression

/// 给微信「系统菜单栏」里的小图标加编号。
///
/// 微信 4.x 是 Qt 应用，菜单栏图标是 QSystemTrayIcon，图片编译在
/// Contents/Resources/wechat.dylib 的 Qt 资源段里（不是 Assets.car，也不是散文件）。
/// 实测（4.x，2026-10）：一张 44×36 的黑色模板 PNG，通用二进制里 arm64/x86_64 各一份，
/// 每份前面紧挨着 4 字节大端长度（Qt rcc 未压缩条目格式）。
///
/// 做法：在 dylib 里找到这些 PNG → 右下角挖出带编号的实心圆 →
/// 用自带的极简 PNG 编码器写回（保证不比原图大），并改写前面的长度字段。
/// 剩余字节保持原样，Qt 按长度字段读取，不受影响。
///
/// ★ 必须在重签之前执行。
enum TrayIconPatcher {
    /// 已知的菜单栏图标像素尺寸（22×18pt 的 1x/2x/3x）。
    private static let traySizes: Set<[Int]> = [[22, 18], [44, 36], [66, 54]]
    private static let pngSig = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let iend = Data("IEND".utf8)

    @discardableResult
    static func patch(app: URL, label: String) throws -> Int {
        let dylib = app.appendingPathComponent("Contents/Resources/wechat.dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            Log.warn("未找到 wechat.dylib，跳过菜单栏图标")
            return 0
        }
        let data = try Data(contentsOf: dylib, options: .alwaysMapped)
        var patches: [(offset: Int, oldLength: Int, png: Data)] = []

        var cursor = data.startIndex
        while let r = data.range(of: pngSig, in: cursor..<data.endIndex) {
            let o = r.lowerBound
            cursor = r.upperBound
            guard o - 4 >= data.startIndex, o + 24 <= data.endIndex else { continue }
            let w = Int(be32(data, o + 16)), h = Int(be32(data, o + 20))
            guard traySizes.contains([w, h]) else { continue }
            guard let e = data.range(of: iend, in: o..<min(o + 1_000_000, data.endIndex)) else { continue }
            let length = e.upperBound + 4 - o     // 含 IEND 的 CRC
            guard Int(be32(data, o - 4)) == length else { continue }   // 必须是 rcc 条目，防误改

            let original = data.subdata(in: o..<(o + length))
            guard let src = CGImageSourceCreateWithData(original as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let stamped = IconBadger.stampStatus(img, label: label),
                  let png = encodePNG(stamped), png.count <= length else {
                Log.warn("菜单栏图标偏移 \(o) 处理失败，跳过")
                continue
            }
            patches.append((o, length, png))
        }

        guard !patches.isEmpty else {
            Log.warn("wechat.dylib 里没找到菜单栏图标（微信版本可能变了）")
            return 0
        }

        // 只原地改写这几 KB：APFS 克隆的其余数据块继续与官方微信共享，不额外占 300+MB 磁盘。
        let fh = try FileHandle(forUpdating: dylib)
        defer { try? fh.close() }
        for p in patches {
            var block = Data()
            appendBE(&block, UInt32(p.png.count))
            block.append(p.png)
            try fh.seek(toOffset: UInt64(p.offset - 4))
            try fh.write(contentsOf: block)
        }
        Log.info("菜单栏图标已加编号 \(label)，共 \(patches.count) 处")
        return patches.count
    }

    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        d[i..<(i + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    // MARK: - 极简 PNG 编码（RGBA8，单个 IDAT）

    static func encodePNG(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 反预乘 + 每行前加滤波字节 0
        var raw = [UInt8]()
        raw.reserveCapacity((w * 4 + 1) * h)
        for y in 0..<h {
            raw.append(0)
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = px[i + 3]
                if a == 0 {
                    raw += [0, 0, 0, 0]
                } else {
                    for c in 0..<3 { raw.append(UInt8(min(255, Int(px[i + c]) * 255 / Int(a)))) }
                    raw.append(a)
                }
            }
        }
        guard let deflated = deflate(raw) else { return nil }
        var zlib = Data([0x78, 0x9C])
        zlib.append(deflated)
        appendBE(&zlib, adler32(raw))

        var ihdr = Data()
        appendBE(&ihdr, UInt32(w)); appendBE(&ihdr, UInt32(h))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])

        var out = pngSig
        chunk(&out, "IHDR", ihdr)
        chunk(&out, "IDAT", zlib)
        chunk(&out, "IEND", Data())
        return out
    }

    private static func deflate(_ input: [UInt8]) -> Data? {
        let cap = input.count + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = compression_encode_buffer(&dst, cap, input, input.count, nil, COMPRESSION_ZLIB)
        return n > 0 ? Data(dst[0..<n]) : nil   // Apple 的 ZLIB 输出是裸 deflate 流
    }

    private static func chunk(_ out: inout Data, _ type: String, _ body: Data) {
        appendBE(&out, UInt32(body.count))
        var typed = Data(type.utf8)
        typed.append(body)
        out.append(typed)
        appendBE(&out, crc32(typed))
    }

    private static func appendBE(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func adler32(_ d: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for x in d { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        return (b << 16) | a
    }
}
