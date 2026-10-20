import Foundation

/// 掐掉 Sparkle 自动更新。
///
/// 为什么必须做：Sparkle 的更新方式是整包替换 App bundle。一旦实例自行更新，
/// 我们注入的 LSEnvironment 会被官方 Info.plist 覆盖，实例退化成
/// "双击就把数据写进真实 ~/Documents" 的裸微信——这是最难排查的一类故障。
enum UpdateDisabler {
    static func disable(app: URL, bundleID: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try IdentityRewriter.mutatePlist(plist) { dict in
            dict.removeValue(forKey: "SUPublicEDKey")
            dict.removeValue(forKey: "SUEnableInstallerLauncherService")
            dict.removeValue(forKey: "SUFeedURL")
        }

        // Sparkle 还会读 UserDefaults，双保险。
        for (key, value) in [("SUAutomaticallyUpdate", "false"), ("SUEnableAutomaticChecks", "false")] {
            _ = try? Shell.run("/usr/bin/defaults", ["write", bundleID, key, "-bool", value], allowFailure: true)
        }
    }
}
