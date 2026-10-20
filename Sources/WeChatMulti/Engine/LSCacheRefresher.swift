import Foundation

/// 刷新 LaunchServices 缓存。
///
/// 这一步漏掉会导致 LSEnvironment **完全不生效**：实例看起来能启动，
/// 但数据写进真实 ~/Documents —— 最危险的一类静默失败。
enum LSCacheRefresher {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func refresh(app: URL) throws {
        try Shell.run(lsregister, ["-f", app.path])
    }
}
