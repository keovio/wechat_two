import Foundation

/// 递归重签整棵 App 包。
///
/// 三条铁律：
///   1. **由内向外** —— 先签最深层的 Mach-O，再签嵌套 bundle，最后签顶层 .app。
///      顺序错了 codesign 会报 "code object is not signed at all"。
///   2. **不用 --deep** —— 它不可靠且会漏掉部分组件，自行遍历更可控。
///   3. **entitlements 绝不含 app-sandbox** —— 带沙盒的 ad-hoc 签名会被 macOS
///      在 _libsecinit_appsandbox 处直接 SIGTRAP（已用 5 行 C 程序对照实验证实）。
enum Resigner {
    /// 去沙盒授权的三个 cs.* 豁免，缺一不可：
    /// 微信内部有大量自研 dylib 与 dlopen，去掉 hardened runtime 后仍需放开库校验。
    static func entitlementsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.cs.disable-library-validation</key>
            <true/>
            <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
            <true/>
            <key>com.apple.security.cs.allow-dyld-environment-variables</key>
            <true/>
        </dict>
        </plist>
        """
    }

    struct Report {
        var machoSigned = 0
        var bundlesSigned = 0
        var failures: [String] = []
        var seconds: Double = 0
    }

    static func signAll(app: URL, entitlementsPath: URL) throws -> Report {
        let start = Date()
        var report = Report()

        let allFiles = try enumerateFiles(under: app)

        // ---- 第 1 轮：所有 Mach-O 文件，按路径深度降序（深的先签） ----
        let machos = allFiles
            .filter { isMachO($0) }
            .sorted { pathDepth($0) > pathDepth($1) }

        for file in machos {
            do {
                try signOne(file, entitlements: entitlementsPath)
                report.machoSigned += 1
            } catch {
                report.failures.append("\(file.path): \(error.localizedDescription)")
            }
        }

        // ---- 第 2 轮：所有 bundle（.app/.appex/.xpc/.framework），同样深的先签 ----
        // ★ 必须显式把顶层 app 自己放进来：enumerator 只枚举 root 的内容，
        //   不含 root 本身；漏掉它就会得到 "a sealed resource is missing or invalid"。
        var bundles = allFiles.filter { isBundle($0) }
        bundles.append(app)
        bundles.sort { pathDepth($0) > pathDepth($1) }

        for bundle in bundles {
            do {
                try signOne(bundle, entitlements: entitlementsPath)
                report.bundlesSigned += 1
            } catch {
                report.failures.append("\(bundle.path): \(error.localizedDescription)")
            }
        }

        report.seconds = Date().timeIntervalSince(start)
        return report
    }

    /// 单个目标签名。--force 覆盖已有签名，--timestamp=none 避免网络请求。
    static func signOne(_ url: URL, entitlements: URL) throws {
        let args = [
            "--force",
            "--sign", "-",
            "--timestamp=none",
            "--entitlements", entitlements.path,
            url.path,
        ]
        try Shell.run("/usr/bin/codesign", args)
    }

    // MARK: - 探测

    /// 读文件头魔数判断是否 Mach-O。比"可执行位"准确得多（有 75 个可执行但非 Mach-O 的文件）。
    static func isMachO(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch magic {
        case 0xfeedface, 0xcefaedfe,   // 32 位
             0xfeedfacf, 0xcffaedfe,   // 64 位
             0xcafebabe, 0xbebafeca,   // FAT
             0xcafebabf, 0xbfbafeca:   // FAT64
            return true
        default:
            return false
        }
    }

    static func isBundle(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }

        switch url.pathExtension {
        case "app", "appex", "xpc":
            return fm.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
        case "framework":
            // Framework 的 Info.plist 在 Resources/ 下（版本化布局则为 Versions/*/Resources/）。
            return fm.fileExists(atPath: url.appendingPathComponent("Resources/Info.plist").path)
                || fm.fileExists(atPath: url.appendingPathComponent("Versions/Current/Resources/Info.plist").path)
        default:
            return false
        }
    }

    static func pathDepth(_ url: URL) -> Int {
        url.pathComponents.count
    }

    /// 递归枚举普通文件。跳过符号链接（用 URL.resourceValues 判定），
    /// 但 Framework 里的 Versions/Current 正是符号链接，真正的实体在 A/ 下，所以跳过是安全的。
    /// 递归枚举 root 下的全部条目（**文件和目录都要**，因为 .app/.appex/.xpc/.framework 都是目录）。
    /// 只跳过符号链接：Framework 的 Versions/Current 只是指向实体的链接，跟随会重复签同一份文件。
    static func enumerateFiles(under root: URL) throws -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return [] }

        var items: [URL] = []
        for case let url as URL in en {
            guard let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { continue }
            if rv.isSymbolicLink == true { continue }
            items.append(url)
        }
        return items
    }

    /// 验收用：全包签名校验。
    static func verify(app: URL) -> (ok: Bool, detail: String) {
        guard let r = try? Shell.run("/usr/bin/codesign", ["-v", "--verbose=2", app.path], allowFailure: true) else {
            return (false, "无法执行 codesign")
        }
        return (r.ok, r.ok ? "签名有效" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
