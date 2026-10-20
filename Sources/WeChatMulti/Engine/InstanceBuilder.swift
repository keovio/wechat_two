import Foundation

/// 11 步创建流水线 —— 全流程唯一入口。
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

    /// 创建（或重建）实例。
    ///
    /// ★ 原子性：新 App 包先在暂存区（Paths.stagingBundle）完成克隆 → 改写 → 重签 → 校验，
    ///   全部通过后才用 renamex_np(RENAME_SWAP) 与现有 App 原子互换。
    ///   任何一步失败，~/Applications 里的旧实例原封不动，用户照常能用。
    ///
    /// - Parameter onProgress: 回调发生在主线程之外，UI 层自行切回主线程。
    /// - Parameter allowOverwrite: 仅 rebuild 内部使用。已登记实例默认禁止被 create 覆盖，
    ///   否则会把它正在使用的 App 包静默换掉。
    static func create(id: String,
                       source: WeChatLocator.Info,
                       allowOverwrite: Bool = false,
                       onProgress: ((Progress) -> Void)? = nil) throws -> Outcome {
        let fm = FileManager.default
        let total = 11
        func step(_ n: Int, _ title: String) {
            Log.info("[" + id + "] 步骤 " + String(n) + "/" + String(total) + " " + title)
            onProgress?(Progress(step: n, total: total, title: title))
        }

        let app = Paths.appBundle(id)
        let staging = Paths.stagingBundle(id)
        let home = Paths.home(id)
        let displayName = Paths.displayName(for: id)

        // 已登记的实例不允许被 create 静默覆盖 —— 用户应该走「重建」。
        let registered = ((try? InstanceStore.load())?.instances.contains { $0.id == id }) ?? false
        if registered && !allowOverwrite {
            throw BuildError.instanceExists(id)
        }

        // ---- 1. 体检 ----
        step(1, "校验官方微信")
        Log.info("[" + id + "] 源版本 " + source.version + " build " + source.build + " team " + (source.teamID ?? "nil"))

        // 目标目录必须在克隆之前就位：clonefile 与 CFFIXED_USER_HOME 都不会自建中间目录。
        try Paths.ensureSupportDirs()
        try Paths.ensureAppsDir()
        try Paths.ensureHomeDir(id)
        try fm.createDirectory(at: Paths.stagingDir, withIntermediateDirectories: true)

        // 上次构建中断留下的暂存残骸，直接清掉。正式位置的 App 一律不碰。
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        // 失败时清理暂存区，正式 App 不受影响。
        var committed = false
        defer {
            if !committed { try? fm.removeItem(at: staging) }
        }

        // ---- 2. 克隆到暂存区 ----
        step(2, "APFS 克隆")
        try AppCloner.clone(from: source.bundlePath, to: staging)

        // ---- 3/4. 改写身份 ----
        step(3, "改写 bundle id")
        step(4, "改写显示名")
        let identity = try IdentityRewriter.rewrite(app: staging, id: id, displayName: displayName)
        Log.info("[" + id + "] bundle id=" + identity.bundleID + " 名=" + identity.displayName
                 + " plist改=" + String(identity.plistEdits) + " strings改=" + String(identity.stringsEdits))

        // ---- 5. 编号角标图标（失败不致命，只是少了角标） ----
        step(5, "生成编号角标图标")
        var badged = false
        do {
            try IconBadger.apply(app: staging, sourceApp: source.bundlePath, label: String(Int(id) ?? 0))
            badged = true
        } catch {
            Log.warn("[" + id + "] 角标图标生成失败，沿用官方图标：" + error.localizedDescription)
        }
        IconBadger.badgeStatusIcons(app: staging, label: String(Int(id) ?? 0))
        do {
            try TrayIconPatcher.patch(app: staging, label: String(Int(id) ?? 0))
        } catch {
            Log.warn("[" + id + "] 菜单栏图标改写失败：" + error.localizedDescription)
        }

        // ---- 6. 注入数据根 ----
        step(6, "注入 CFFIXED_USER_HOME")
        try EnvInjector.inject(app: staging, home: home)
        guard EnvInjector.injectedHome(app: staging) == home.path else {
            throw BuildError.injectionVerifyFailed
        }

        // ---- 7. 禁用自更新 ----
        step(7, "禁用 Sparkle 自更新")
        try UpdateDisabler.disable(app: staging, bundleID: identity.bundleID)

        // ---- 8. 重签 ----
        step(8, "递归重签全部 Mach-O 与 bundle")
        let entPath = Paths.supportRoot.appendingPathComponent("entitlements.plist")
        try Resigner.entitlementsXML().data(using: .utf8)!.write(to: entPath)
        let report = try Resigner.signAll(app: staging, entitlementsPath: entPath)
        Log.info("[" + id + "] 签名 Mach-O=" + String(report.machoSigned)
                 + " bundle=" + String(report.bundlesSigned)
                 + " 耗时=" + String(format: "%.2fs", report.seconds)
                 + " 失败=" + String(report.failures.count))
        if !report.failures.isEmpty {
            throw BuildError.signFailures(report.failures)
        }

        // ---- 9. 清隔离属性 + 替换前校验 ----
        step(9, "清除隔离属性并校验签名")
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", staging.path], allowFailure: true)
        let verify = Resigner.verify(app: staging)
        guard verify.ok else { throw BuildError.verifyFailed(verify.detail) }

        // ---- 10. 原子替换 + 刷新 LaunchServices ----
        // 签名不包含 bundle 路径，LSEnvironment 指向的 home 也与 App 位置无关，所以挪位置是安全的。
        step(10, "替换实例并刷新 LaunchServices")
        try atomicReplace(staging: staging, destination: app)
        committed = true
        try? fm.removeItem(at: staging)   // RENAME_SWAP 后这里是旧 App 包
        try LSCacheRefresher.refresh(app: app)
        if badged { IconBadger.flushIconCache(app: app) }

        // ---- 11. 落库 ----
        step(11, "写入注册表")
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

    /// 目标已存在时用 renamex_np(RENAME_SWAP) 原子互换（APFS 支持）；不存在则直接 rename。
    /// 跨卷等少见情况退化为「删旧 → 挪新」。
    static func atomicReplace(staging: URL, destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: staging, to: destination)
            return
        }
        let rc = staging.path.withCString { src in
            destination.path.withCString { dst in
                renamex_np(src, dst, UInt32(RENAME_SWAP))
            }
        }
        if rc == 0 { return }
        let err = errno
        Log.warn("RENAME_SWAP 失败 (errno=\(err))，退化为删除后移动：" + destination.path)
        try fm.removeItem(at: destination)
        try fm.moveItem(at: staging, to: destination)
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

    /// 重建实例：用新版本官方微信重新生成 App 包。
    ///
    /// 数据根在 App 包之外（Application Support），而新包是在暂存区建好后原子替换的，
    /// 所以登录态与聊天记录全程不被触碰，失败时旧实例也完好无损。
    /// 调用前必须先退出该实例（运行中的进程还映射着旧包里的文件）。
    static func rebuild(id: String, source: WeChatLocator.Info, onProgress: ((Progress) -> Void)? = nil) throws -> Outcome {
        let outcome = try create(id: id, source: source, allowOverwrite: true, onProgress: onProgress)
        Log.info("[" + id + "] 重建完成，数据目录保持 " + Paths.home(id).path)
        return outcome
    }

    enum BuildError: Error, LocalizedError {
        case instanceExists(String)
        case injectionVerifyFailed
        case signFailures([String])
        case verifyFailed(String)

        var errorDescription: String? {
            switch self {
            case .instanceExists(let id):
                return "实例 " + id + " 已存在。若想换用新版本官方微信，请使用「重建」（会保留数据）。"
            case .injectionVerifyFailed:
                return "LSEnvironment 写入后读回校验失败，已中止以免数据写进真实 ~/Documents。"
            case .signFailures(let list):
                let head = list.prefix(5).joined(separator: "\n  ")
                return "有 " + String(list.count) + " 个组件签名失败：\n  " + head
            case .verifyFailed(let detail):
                return "新 App 包签名校验未通过，已放弃替换（旧实例未受影响）：\n" + detail
            }
        }
    }
}
