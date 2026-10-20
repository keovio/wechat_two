import Foundation

/// 10 步创建流水线 —— 全流程唯一入口。
///
/// 每一步都可单独重试，失败会带上"卡在哪一步"的信息，便于事后排查。
///
/// 落盘分成两块（见 Paths）：
/// - 克隆体本体 → `~/Applications/微信 N.app`（启动台/Dock 能看到）
/// - 数据根   → `.../WeChatMulti/instances/NN`（CFFIXED_USER_HOME 指向它）
/// 二者分离，所以「用新版官方微信重建」只会重刷 App，绝不碰登录态。
enum InstanceBuilder {
    struct Progress {
        let step: Int
        let total: Int
        let title: String
    }

    struct Outcome {
        let record: InstanceRecord
        let signReport: Resigner.Report
    }

    /// 创建实例。
    /// - Parameter onProgress: 回调发生在主线程之外，UI 层自行切回主线程。
    /// - Parameter allowOverwrite: 仅 rebuild 内部使用。已登记实例默认禁止被 create 覆盖，
    ///   否则会把它正在使用的 App 包静默换掉。
    static func create(id: String,
                       source: WeChatLocator.Info,
                       allowOverwrite: Bool = false,
                       onProgress: ((Progress) -> Void)? = nil) throws -> Outcome {
        let fm = FileManager.default
        let total = 10
        func step(_ n: Int, _ title: String) -> Progress {
            let p = Progress(step: n, total: total, title: title)
            Log.info("[" + id + "] 步骤 " + String(n) + "/" + String(total) + " " + title)
            onProgress?(p)
            return p
        }

        let app = Paths.appBundle(id)
        let home = Paths.home(id)
        let displayName = Paths.displayName(for: id)

        // 已登记的实例不允许被 create 静默覆盖 —— 用户应该走「重建」。
        let registered = ((try? InstanceStore.load())?.instances.contains { $0.id == id }) ?? false
        if registered && !allowOverwrite {
            throw BuildError.instanceExists(id)
        }

        // ---- 1. 体检 ----
        _ = step(1, "校验官方微信")
        Log.info("[" + id + "] 源版本 " + source.version + " build " + source.build + " team " + (source.teamID ?? "nil"))

        // 目标目录必须在克隆之前就位：clonefile 与 CFFIXED_USER_HOME 都不会自建中间目录。
        try Paths.ensureSupportDirs()
        try Paths.ensureAppsDir()
        try Paths.ensureHomeDir(id)

        // 上次创建中断留下的残骸：只清 App 包，绝不碰数据目录。
        if fm.fileExists(atPath: app.path) {
            Log.warn("[" + id + "] 清除旧 App 包后重建：" + app.path)
            try fm.removeItem(at: app)
        }

        // ---- 2. 克隆 ----
        _ = step(2, "APFS 克隆")
        try AppCloner.clone(from: source.bundlePath, to: app)

        // ---- 3. 改写 bundle id ----
        _ = step(3, "改写 bundle id")

        // ---- 4. 改写显示名 ----
        _ = step(4, "改写显示名")
        let identity = try IdentityRewriter.rewrite(app: app, id: id, displayName: displayName)
        Log.info("[" + id + "] bundle id=" + identity.bundleID + " 名=" + identity.displayName
                 + " plist改=" + String(identity.plistEdits) + " strings改=" + String(identity.stringsEdits))

        // ---- 5. 注入数据根 ----
        _ = step(5, "注入 CFFIXED_USER_HOME")
        try EnvInjector.inject(app: app, home: home)
        guard EnvInjector.injectedHome(app: app) == home.path else {
            throw BuildError.injectionVerifyFailed
        }

        // ---- 6. 禁用自更新 ----
        _ = step(6, "禁用 Sparkle 自更新")
        try UpdateDisabler.disable(app: app, bundleID: identity.bundleID)

        // ---- 7. 重签 ----
        _ = step(7, "递归重签全部 Mach-O 与 bundle")
        let entPath = Paths.supportRoot.appendingPathComponent("entitlements.plist")
        try Resigner.entitlementsXML().data(using: .utf8)!.write(to: entPath)
        let report = try Resigner.signAll(app: app, entitlementsPath: entPath)
        Log.info("[" + id + "] 签名 Mach-O=" + String(report.machoSigned)
                 + " bundle=" + String(report.bundlesSigned)
                 + " 耗时=" + String(format: "%.2fs", report.seconds)
                 + " 失败=" + String(report.failures.count))
        if !report.failures.isEmpty {
            throw BuildError.signFailures(report.failures)
        }

        // ---- 8. 清隔离属性 ----
        _ = step(8, "清除隔离属性")
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", app.path], allowFailure: true)

        // ---- 9. 刷新 LaunchServices 缓存 ----
        _ = step(9, "刷新 LaunchServices 缓存")
        try LSCacheRefresher.refresh(app: app)

        // ---- 10. 落库 ----
        _ = step(10, "写入注册表")
        var config = try InstanceStore.load()
        let record = InstanceRecord(
            id: id,
            name: displayName,
            sourceVersion: source.version,
            bundleID: identity.bundleID,
            createdAt: Date()
        )
        config.instances.removeAll { $0.id == id }
        config.instances.append(record)
        config.instances.sort { $0.id < $1.id }
        try InstanceStore.save(config)

        return Outcome(record: record, signReport: report)
    }

    /// 删除实例。只删该实例的 App 包与数据根，绝不触碰官方微信。
    static func delete(id: String, removeData: Bool) throws {
        var config = try InstanceStore.load()
        config.instances.removeAll { $0.id == id }
        try InstanceStore.save(config)

        let fm = FileManager.default
        let app = Paths.appBundle(id)
        if fm.fileExists(atPath: app.path) {
            try fm.removeItem(at: app)
        }
        if removeData {
            let home = Paths.home(id)
            if fm.fileExists(atPath: home.path) {
                try fm.removeItem(at: home)
            }
        }
    }

    /// 重建实例：用新版本官方微信克隆，保留旧数据根。
    /// 做法是先把数据根挪到一旁，重建 App 包，完成后挪回来。
    static func rebuild(id: String, source: WeChatLocator.Info, onProgress: ((Progress) -> Void)? = nil) throws -> Outcome {
        let fm = FileManager.default
        let home = Paths.home(id)
        let parked = Paths.instancesDir.appendingPathComponent(id + ".parked", isDirectory: true)

        var hasData = false
        if fm.fileExists(atPath: home.path) {
            if fm.fileExists(atPath: parked.path) { try fm.removeItem(at: parked) }
            try fm.moveItem(at: home, to: parked)
            hasData = true
        }

        let outcome: Outcome
        do {
            outcome = try create(id: id, source: source, allowOverwrite: true, onProgress: onProgress)
        } catch {
            // 重建失败时把数据挪回原位，绝不能让用户以为聊天记录丢了。
            if hasData {
                let back = Paths.home(id)
                try? Paths.ensureHomeDir(id)
                if fm.fileExists(atPath: back.path) { try? fm.removeItem(at: back) }
                try? fm.moveItem(at: parked, to: back)
                Log.error("[" + id + "] 重建失败，数据已还原到 " + back.path)
            }
            throw error
        }

        if hasData {
            let newHome = Paths.home(id)
            if fm.fileExists(atPath: newHome.path) { try? fm.removeItem(at: newHome) }
            try fm.moveItem(at: parked, to: newHome)
            // 路径未变，但为稳妥起见重新确认注入值。
            let app = Paths.appBundle(id)
            try EnvInjector.inject(app: app, home: newHome)
            try LSCacheRefresher.refresh(app: app)
        }

        Log.info("[" + id + "] 重建完成，数据保留=" + String(hasData))
        return outcome
    }

    enum BuildError: Error, LocalizedError {
        case instanceExists(String)
        case injectionVerifyFailed
        case signFailures([String])

        var errorDescription: String? {
            switch self {
            case .instanceExists(let id):
                return "实例 " + id + " 已存在。若想换用新版本官方微信，请使用「重建」（会保留数据）。"
            case .injectionVerifyFailed:
                return "LSEnvironment 写入后读回校验失败，已中止以免数据写进真实 ~/Documents。"
            case .signFailures(let list):
                let head = list.prefix(5).joined(separator: "\n  ")
                return "有 " + String(list.count) + " 个组件签名失败：\n  " + head
            }
        }
    }
}
