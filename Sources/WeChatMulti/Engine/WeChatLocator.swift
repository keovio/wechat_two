import Foundation

/// 官方微信的定位与体检。
enum WeChatLocator {
    static let officialPath = URL(fileURLWithPath: "/Applications/WeChat.app")

    struct Info {
        let bundlePath: URL
        let version: String
        let build: String
        let bundleID: String
        let teamID: String?
    }

    static func locate() throws -> Info {
        let fm = FileManager.default
        guard fm.fileExists(atPath: officialPath.path) else {
            throw LocatorError.notInstalled
        }
        let plistURL = officialPath.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LocatorError.unreadablePlist
        }

        let exec = officialPath.appendingPathComponent("Contents/MacOS/WeChat")
        let team = codesignTeamID(at: exec)

        return Info(
            bundlePath: officialPath,
            version: plist["CFBundleShortVersionString"] as? String ?? "未知",
            build: plist["CFBundleVersion"] as? String ?? "未知",
            bundleID: plist["CFBundleIdentifier"] as? String ?? "com.tencent.xinWeChat",
            teamID: team
        )
    }

    /// 只读 Info.plist 拿版本号，不调用 codesign。
    /// 菜单每次展开都会用它比对"实例是否落后于官方微信"，所以必须足够轻。
    static func officialVersion() -> String? {
        let plistURL = officialPath.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// 读 TeamIdentifier。失败返回 nil 而不是抛错——调用方用它做"官方未被改动"的验收。
    static func codesignTeamID(at url: URL) -> String? {
        guard let r = try? Shell.run("/usr/bin/codesign", ["-dv", url.path], allowFailure: true) else { return nil }
        for line in r.stderr.split(separator: "\n") {
            if let range = line.range(of: "TeamIdentifier=") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    enum LocatorError: Error, LocalizedError {
        case notInstalled
        case unreadablePlist
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "未找到 /Applications/WeChat.app，请先安装微信。"
            case .unreadablePlist: return "无法读取微信 Info.plist，安装可能已损坏。"
            }
        }
    }
}
