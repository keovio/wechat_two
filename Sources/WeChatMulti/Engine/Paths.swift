import Foundation

/// 全部落盘位置的唯一来源。改这里就能整体搬家。
///
/// 布局刻意分成「应用区」与「数据区」两块：
/// - 应用区 `~/Applications/微信 N.app`                                  ← 克隆体本体
/// - 数据区 `~/Library/Application Support/WeChatMulti/instances/NN/home` ← CFFIXED_USER_HOME
///
/// 分开的原因：实例 .app 必须放进启动台 / Spotlight / Dock 会扫描的目录，
/// 用户才能像普通 App 一样双击启动；而登录态与聊天记录留在 Application Support，
/// 于是「用新版官方微信重建实例」不会碰到数据。
enum Paths {
    /// `~/Library/Application Support/WeChatMulti`
    ///
    /// 可用 WECHATMULTI_ROOT 覆盖，仅供排障与自动化测试使用；
    /// 正常运行时不要设置，否则实例数据会落在非预期位置。
    static var supportRoot: URL {
        if let override = ProcessInfo.processInfo.environment["WECHATMULTI_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WeChatMulti", isDirectory: true)
    }

    /// 实例 App 的落点，默认 `~/Applications`。
    ///
    /// 这是用户级应用目录：启动台与 Spotlight 都会扫描，Dock 也能正常驻留。
    /// 放在 `~/Library/Application Support` 下的话用户"根本看不见"，多开就失去意义。
    ///
    /// 可用 WECHATMULTI_APPS 覆盖，仅供自动化测试使用（避免污染真实 ~/Applications）。
    static var appsDir: URL {
        if let override = ProcessInfo.processInfo.environment["WECHATMULTI_APPS"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    /// 实例数据根目录：每个实例一个子目录，内含 home/。
    static var instancesDir: URL { supportRoot.appendingPathComponent("instances", isDirectory: true) }
    static var configFile: URL { supportRoot.appendingPathComponent("config.json") }
    static var logsDir: URL { supportRoot.appendingPathComponent("logs", isDirectory: true) }

    /// 显示名。编号 01 → 「微信 1」，02 → 「微信 2」，以此类推。
    ///
    /// 刻意**不带官方的「微信」**：实例会和官方微信同时出现在启动台、Dock 与
    /// 应用切换器里，若两者同名，用户根本分不清点的是哪一个。
    ///
    /// 同时决定 .app 的文件名与 Info.plist 里的显示名，
    /// 所以实例在启动台、Dock、菜单栏里的名字完全一致。
    static func displayName(for id: String) -> String {
        let n = Int(id) ?? 0
        return n >= 1 ? "微信 \(n)" : "微信"
    }

    /// `~/Applications/微信 N.app` —— 克隆体本体
    static func appBundle(_ id: String) -> URL {
        appsDir.appendingPathComponent(displayName(for: id) + ".app", isDirectory: true)
    }

    /// `instances/NN` —— 该实例的数据根，内含 home/
    static func home(_ id: String) -> URL {
        instancesDir.appendingPathComponent(id, isDirectory: true)
    }

    /// 构建暂存区：新 App 包先在这里克隆、改写、重签、校验，全部通过后才原子替换到 ~/Applications。
    /// 与 appsDir 同处用户数据卷，保证 rename 是同卷原子操作。
    static var stagingDir: URL { supportRoot.appendingPathComponent("staging", isDirectory: true) }

    static func stagingBundle(_ id: String) -> URL {
        stagingDir.appendingPathComponent(id + ".app", isDirectory: true)
    }

    static func instancePlist(_ id: String) -> URL {
        appBundle(id).appendingPathComponent("Contents/Info.plist")
    }

    static func ensureSupportDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: instancesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    /// `~/Applications` 在少数系统上不存在，克隆前必须先建出来。
    static func ensureAppsDir() throws {
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
    }

    /// 单个实例的数据目录。clonefile 与 CFFIXED_USER_HOME 都要求它先存在。
    static func ensureHomeDir(_ id: String) throws {
        try FileManager.default.createDirectory(at: home(id), withIntermediateDirectories: true)
    }
}
