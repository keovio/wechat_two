import Foundation

/// 核心：把数据根钉进 App 包本身。
///
/// 在克隆体 Info.plist 写入 LSEnvironment.CFFIXED_USER_HOME，
/// LaunchServices 在启动时注入该变量，微信便把 NSDocumentDirectory
/// 解析到实例目录，而不是真实的 ~/Documents。
///
/// 注意：LSEnvironment 的值不做变量展开，必须是写死的绝对路径。
enum EnvInjector {
    static func inject(app: URL, home: URL) throws {
        let fm = FileManager.default

        // home 必须预先存在，否则微信可能拒绝启动或静默回退到真实目录。
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let plist = app.appendingPathComponent("Contents/Info.plist")
        try IdentityRewriter.mutatePlist(plist) { dict in
            var env = dict["LSEnvironment"] as? [String: String] ?? [:]
            env["CFFIXED_USER_HOME"] = home.path
            dict["LSEnvironment"] = env
        }
    }

    /// 读回当前注入值，用于自检。
    static func injectedHome(app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = dict["LSEnvironment"] as? [String: String] else { return nil }
        return env["CFFIXED_USER_HOME"]
    }
}
