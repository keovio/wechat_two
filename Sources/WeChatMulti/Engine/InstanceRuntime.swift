import AppKit
import Foundation

/// 实例的启停与状态。
///
/// ★ 启动必须走 NSWorkspace（LaunchServices），绝不能 posix_spawn 二进制：
///   只有经过 LaunchServices，Info.plist 里的 LSEnvironment 才会被注入。
///   直跑 Contents/MacOS/WeChat 会把数据写进真实 ~/Documents。
enum InstanceRuntime {
    enum Status: String {
        case running = "运行中"
        case stopped = "已停止"
        case missing = "文件缺失"

        var symbol: String {
            switch self {
            case .running: return "●"
            case .stopped: return "○"
            case .missing: return "⚠"
            }
        }
    }

    static func status(of record: InstanceRecord) -> Status {
        guard FileManager.default.fileExists(atPath: record.appPath) else { return .missing }
        return runningApplications(bundleID: record.bundleID).isEmpty ? .stopped : .running
    }

    static func runningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    /// 经 LaunchServices 启动。openApplication 会读 Info.plist 并注入 LSEnvironment。
    @discardableResult
    static func start(_ record: InstanceRecord, force: Bool = false) throws -> Int {
        let appURL = URL(fileURLWithPath: record.appPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw RuntimeError.appMissing(record.appPath)
        }

        let existing = runningApplications(bundleID: record.bundleID)
        if !existing.isEmpty && !force {
            return Int(existing[0].processIdentifier)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false

        var launchedPID: Int = 0
        var launchError: Error?
        let sem = DispatchSemaphore(value: 0)

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            if let app { launchedPID = Int(app.processIdentifier) }
            launchError = error
            sem.signal()
        }

        // 给 LaunchServices 一点时间完成握手；超时不视为失败（进程通常已起）。
        _ = sem.wait(timeout: .now() + 10)

        if let e = launchError { throw RuntimeError.launchFailed(e.localizedDescription) }
        return launchedPID
    }

    /// 优雅停止：先 quit（等价 SIGTERM），超时后强杀残留。
    /// ★ 必须按"该实例 App 包路径"清场，而不能只看 NSRunningApplication：
    ///   WeChatAppEx / Helper / crashpad_handler 是独立进程，主应用退出后常常滞留，
    ///   它们仍持有实例 home 里的文件句柄，会让后续 rebuild/delete 失败。
    /// 返回结束掉的进程数。
    @discardableResult
    static func stop(_ record: InstanceRecord, timeout: TimeInterval = 8) throws -> Int {
        let before = processCount(record: record)

        for app in runningApplications(bundleID: record.bundleID) { app.terminate() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if processCount(record: record) == 0 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }

        // 强杀仍活着的（按实例包路径匹配，不会误伤官方微信或管理器自身）。
        if processCount(record: record) > 0 {
            let appPath = record.appPath
            _ = try? Shell.run("/usr/bin/pkill", ["-9", "-f", appPath], allowFailure: true)
            // LaunchServices 注册的 bundle id 路径也一并清一次。
            for app in runningApplications(bundleID: record.bundleID) { app.forceTerminate() }
            Thread.sleep(forTimeInterval: 1.0)
        }

        let after = processCount(record: record)
        return max(0, before - after)
    }

    /// 该实例占用的所有进程数（含 WeChatAppEx / Helper / crashpad_handler 等子进程）。
    /// 按实例 App 包路径匹配：既避开只认 bundle id 时漏掉子进程，也不会误伤官方微信。
    static func processCount(record: InstanceRecord) -> Int {
        processCount(matching: record.appPath)
    }

    static func processCount(matching pattern: String) -> Int {
        guard let r = try? Shell.run("/usr/bin/pgrep", ["-f", pattern], allowFailure: true) else { return 0 }
        return r.stdout.split(separator: "\n").filter { !$0.isEmpty }.count
    }

    enum RuntimeError: Error, LocalizedError {
        case appMissing(String)
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .appMissing(let p): return "实例文件不存在：\(p)"
            case .launchFailed(let m): return "启动失败：\(m)"
            }
        }
    }
}
