import Foundation

/// 把克隆体的身份从"官方微信"改成"微信 NN"。
///
/// 改的是两样东西：
///   1. bundle id —— 主 id 加编号后缀，嵌套 5 个组件同步跟随；
///      WeChatAppEx 是独立容器（com.tencent.flue.*），刻意不动。
///   2. 显示名 —— Info.plist 的 CFBundleName / CFBundleDisplayName，
///      以及各 .lproj/InfoPlist.strings（UTF-16，系统在中文环境下优先读它）。
enum IdentityRewriter {
    /// (相对 Contents 的 Info.plist 路径, 旧 id, 新 id 后缀)
    /// 后缀拼接规则：old + suffix。
    static let nestedBundleTargets: [(plistPath: String, oldID: String)] = [
        ("MacOS/XPlayer.app/Contents/Info.plist", "com.tencent.xinWeChat.xplayer"),
        ("MacOS/WeChatHelper.app/Contents/Info.plist", "com.tencent.xinWeChat.WeChatHelper"),
        ("PlugIns/WeChatFileProviderExtension.appex/Contents/Info.plist", "com.tencent.xinWeChat.WeChatFileProviderExtension"),
        ("PlugIns/WeChatMacShare.appex/Contents/Info.plist", "com.tencent.xinWeChat.WeChatMacShare"),
        ("Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/Info.plist", "com.tencent.xinWeChat.InstallerLauncher"),
    ]

    /// 菜单栏 / Dock 上要显示的本地化名字文件（相对 app 根）。
    static let stringsTargets: [String] = [
        "Contents/Resources/zh-Hans.lproj/InfoPlist.strings",
        "Contents/Resources/zh-Hant.lproj/InfoPlist.strings",
        "Contents/MacOS/XPlayer.app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings",
        "Contents/MacOS/WeChatHelper.app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings",
    ]

    struct Result {
        let bundleID: String
        let displayName: String
        let plistEdits: Int
        let stringsEdits: Int
    }

    /// - Parameters:
    ///   - id: 实例编号，如 "02"
    ///   - displayName: 显示名，如 "微信 2"
    static func rewrite(app: URL, id: String, displayName: String) throws -> Result {
        let suffix = id
        let newBundleID = "com.tencent.xinWeChat" + suffix

        var plistEdits = 0
        var stringsEdits = 0

        // 1) 主 Info.plist
        let mainPlist = app.appendingPathComponent("Contents/Info.plist")
        try mutatePlist(mainPlist) { dict in
            dict["CFBundleIdentifier"] = newBundleID
            dict["CFBundleName"] = displayName
            dict["CFBundleDisplayName"] = displayName
        }
        plistEdits += 1

        // 2) 嵌套组件 Info.plist
        for target in nestedBundleTargets {
            let url = app.appendingPathComponent(target.plistPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try mutatePlist(url) { dict in
                dict["CFBundleIdentifier"] = target.oldID + suffix
            }
            plistEdits += 1
        }

        // 3) 本地化显示名
        for rel in stringsTargets {
            let url = app.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let (text, enc) = try StringsFile.read(url)
            let updated = StringsFile.replacing(text, keys: ["CFBundleDisplayName", "CFBundleName"], with: displayName)
            if updated != text {
                try StringsFile.write(updated, to: url, encoding: enc)
                stringsEdits += 1
            }
        }

        return Result(bundleID: newBundleID, displayName: displayName, plistEdits: plistEdits, stringsEdits: stringsEdits)
    }

    /// 读 → 改 → 以 XML plist 写回（原始就是 XML，格式不退化）。
    static func mutatePlist(_ url: URL, _ body: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: url)
        guard var dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw RewriterError.notADictionary(url.path)
        }
        body(&dict)
        let out = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try out.write(to: url)
    }

    enum RewriterError: Error, LocalizedError {
        case notADictionary(String)
        var errorDescription: String? {
            switch self {
            case .notADictionary(let p): return "不是字典类型的 plist：\(p)"
            }
        }
    }
}
