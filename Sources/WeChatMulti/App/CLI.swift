import Foundation

/// 命令行入口。与 GUI 共用同一套 Engine，不存在"两套逻辑"的漂移风险。
enum CLI {
    static func run(command: String, args: [String]) -> Int32 {
        do {
            switch command {
            case "list":
                return try list()
            case "check":
                return try check(args)
            case "create":
                return try create(args)
            case "start":
                return try start(args)
            case "stop":
                return try stop(args)
            case "rebuild":
                return try rebuild(args)
            case "rebuild-all":
                return try rebuildAll()
            case "version", "--version", "-v":
                print("微信多开 " + AppInfo.version + "（build " + AppInfo.build + "）")
                return 0
            case "delete":
                return try delete(args)
            case "doctor":
                return doctor()
            case "help", "--help", "-h":
                printUsage()
                return 0
            default:
                FileHandle.standardError.write(("未知命令：" + command + "\n").data(using: .utf8)!)
                printUsage()
                return 2
            }
        } catch {
            FileHandle.standardError.write(("错误：" + error.localizedDescription + "\n").data(using: .utf8)!)
            return 1
        }
    }

    // MARK: - 子命令

    private static func list() throws -> Int32 {
        let config = try InstanceStore.load()
        if config.instances.isEmpty {
            print("（尚无实例）\n支持目录：" + Paths.supportRoot.path)
            return 0
        }
        print("应用目录：" + Paths.appsDir.path + "（启动台 / Spotlight 可搜到）")
        print("数据目录：" + Paths.supportRoot.path)
        for r in config.instances {
            let status = InstanceRuntime.status(of: r)
            print("")
            print("  " + status.symbol + " " + r.name + "  [ID " + r.id + "]  " + status.rawValue)
            print("     bundle id : " + r.bundleID)
            print("     源版本    : " + r.sourceVersion)
            print("     实例 App  : " + r.appPath)
            print("     数据根    : " + r.homePath)
        }
        return 0
    }

    private static func check(_ args: [String]) throws -> Int32 {
        let config = try InstanceStore.load()
        let targets: [InstanceRecord]
        if let id = args.first {
            targets = config.instances.filter { $0.id == id }
            if targets.isEmpty { throw CLIError.noSuchInstance(id) }
        } else {
            targets = config.instances
        }
        if targets.isEmpty {
            print("（尚无实例，先运行 create）")
            return 0
        }

        var allPassed = true
        for record in targets {
            print("── " + record.name + "（" + record.id + "）")
            for item in SelfCheck.check(record: record) {
                if !item.passed { allPassed = false }
                print("  " + item.symbol + " " + item.title + "：" + item.detail)
            }
        }
        return allPassed ? 0 : 1
    }

    private static func create(_ args: [String]) throws -> Int32 {
        let source = try WeChatLocator.locate()
        print("官方微信 " + source.version + "（build " + source.build + "）"
              + " team=" + (source.teamID ?? "nil"))

        let config = try InstanceStore.load()
        let id = args.first ?? InstanceStore.nextID(existing: config.instances)
        let name = InstanceStore.displayName(for: id)
        print("创建实例 " + id + "「" + name + "」")

        let outcome = try InstanceBuilder.create(id: id, source: source) { p in
            print("  [" + String(p.step) + "/" + String(p.total) + "] " + p.title)
        }

        print("完成：bundle id = " + outcome.record.bundleID)
        print("      实例 App = " + outcome.record.appPath)
        print("      数据根   = " + outcome.record.homePath)
        print("      重签 " + String(outcome.signReport.machoSigned) + " 个 Mach-O / "
              + String(outcome.signReport.bundlesSigned) + " 个 bundle，耗时 "
              + String(format: "%.2fs", outcome.signReport.seconds))
        print("")
        print("—— 隔离自检 ——")
        var ok = true
        for item in SelfCheck.check(record: outcome.record) {
            if !item.passed { ok = false }
            print("  " + item.symbol + " " + item.title + "：" + item.detail)
        }
        return ok ? 0 : 1
    }

    private static func start(_ args: [String]) throws -> Int32 {
        guard let id = args.first else { throw CLIError.missingArgument("实例 ID") }
        guard let record = (try InstanceStore.load()).instances.first(where: { $0.id == id }) else {
            throw CLIError.noSuchInstance(id)
        }
        let pid = try InstanceRuntime.start(record)
        print("已启动 " + record.name + "（pid " + String(pid) + "）")
        return 0
    }

    private static func stop(_ args: [String]) throws -> Int32 {
        guard let id = args.first else { throw CLIError.missingArgument("实例 ID") }
        guard let record = (try InstanceStore.load()).instances.first(where: { $0.id == id }) else {
            throw CLIError.noSuchInstance(id)
        }
        if InstanceRuntime.status(of: record) == .stopped {
            print(record.name + " 本来就未运行")
            return 0
        }
        let n = try InstanceRuntime.stop(record)
        print("已退出 " + record.name + "（结束 " + String(n) + " 个进程，数据保留在 " + record.homePath + "）")
        return 0
    }

    /// 用当前官方微信版本重建实例 App，数据目录原样保留（微信升级后的常规动作）。
    private static func rebuild(_ args: [String]) throws -> Int32 {
        guard let id = args.first else { throw CLIError.missingArgument("实例 ID") }
        guard let record = (try InstanceStore.load()).instances.first(where: { $0.id == id }) else {
            throw CLIError.noSuchInstance(id)
        }
        if InstanceRuntime.status(of: record) == .running {
            print("实例正在运行，先退出…")
            try InstanceRuntime.stop(record)
        }

        let source = try WeChatLocator.locate()
        print("用官方 " + source.version + "（build " + source.build + "）重建实例 "
              + record.name + "（" + id + "），数据目录保留不动")

        let outcome = try InstanceBuilder.rebuild(id: id, source: source) { p in
            print("  [" + String(p.step) + "/" + String(p.total) + "] " + p.title)
        }
        print("完成：数据目录 = " + outcome.record.homePath)
        print("      重签 " + String(outcome.signReport.machoSigned) + " 个 Mach-O / "
              + String(outcome.signReport.bundlesSigned) + " 个 bundle，耗时 "
              + String(format: "%.2fs", outcome.signReport.seconds))
        print("")
        print("—— 隔离自检 ——")
        var ok = true
        for item in SelfCheck.check(record: outcome.record) {
            if !item.passed { ok = false }
            print("  " + item.symbol + " " + item.title + "：" + item.detail)
        }
        return ok ? 0 : 1
    }

    /// 微信升级后：把所有落后于官方版本的实例一次性重建（数据保留）。
    private static func rebuildAll() throws -> Int32 {
        let source = try WeChatLocator.locate()
        let targets = (try InstanceStore.load()).instances.filter { $0.sourceVersion != source.version }
        if targets.isEmpty {
            print("所有实例已是官方 " + source.version + "，无需重建")
            return 0
        }
        var failed = 0
        for record in targets {
            print("── 重建 " + record.name + "（" + record.sourceVersion + " → " + source.version + "）")
            do {
                if InstanceRuntime.status(of: record) == .running {
                    try InstanceRuntime.stop(record)
                }
                _ = try InstanceBuilder.rebuild(id: record.id, source: source) { p in
                    print("  [" + String(p.step) + "/" + String(p.total) + "] " + p.title)
                }
            } catch {
                failed += 1
                print("  ❌ " + error.localizedDescription)
            }
        }
        return failed == 0 ? 0 : 1
    }

    private static func delete(_ args: [String]) throws -> Int32 {
        guard let id = args.first else { throw CLIError.missingArgument("实例 ID") }
        guard let record = (try InstanceStore.load()).instances.first(where: { $0.id == id }) else {
            throw CLIError.noSuchInstance(id)
        }
        if InstanceRuntime.status(of: record) == .running {
            throw CLIError.instanceRunning(id)
        }
        try InstanceBuilder.delete(id: id, removeData: true)
        print("已删除实例 " + record.name + "（数据目录 " + record.homePath + " 一并删除）")
        return 0
    }

    /// 环境体检：报告会影响创建流水线的每一个外部条件。
    private static func doctor() -> Int32 {
        print("数据目录：" + Paths.supportRoot.path)
        print("  存在：" + (FileManager.default.fileExists(atPath: Paths.supportRoot.path) ? "是" : "否"))
        print("应用目录：" + Paths.appsDir.path)
        print("  存在：" + (FileManager.default.fileExists(atPath: Paths.appsDir.path) ? "是" : "否"))

        do {
            let source = try WeChatLocator.locate()
            print("官方微信：" + source.bundlePath.path)
            print("  版本：" + source.version + " build " + source.build)
            print("  bundle id：" + source.bundleID)
            print("  TeamIdentifier：" + (source.teamID ?? "nil")
                  + (source.teamID == "5A4RE8SF68" ? "（正常，未被改动）" : "（⚠︎ 与预期不符）"))
        } catch {
            print("官方微信：❌ " + error.localizedDescription)
        }

        let ls = LSCacheRefresher.lsregister
        print("lsregister：\(ls) " + (FileManager.default.isExecutableFile(atPath: ls) ? "✅" : "❌"))

        let realAppData = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/app_data")
        let realFiles = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/xwechat_files")
        let polluted = FileManager.default.fileExists(atPath: realAppData.path)
            || FileManager.default.fileExists(atPath: realFiles.path)
        print("真实 ~/Documents 污染：" + (polluted ? "❌ 发现 app_data/xwechat_files" : "✅ 干净"))

        let codesign = "/usr/bin/codesign"
        print("codesign：" + (FileManager.default.isExecutableFile(atPath: codesign) ? "✅" : "❌"))

        // 管理器自身不能带沙盒，否则后续所有文件与签名操作都会被系统拒绝。
        if let selfBundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil {
            let r = try? Shell.run(codesign, ["-d", "--entitlements", "-", selfBundle.path], allowFailure: true)
            let hasSandbox = (r?.stdout.contains("app-sandbox") ?? false) || (r?.stderr.contains("app-sandbox") ?? false)
            print("管理器沙盒：" + (hasSandbox ? "❌ 启用了 App Sandbox，必须去掉" : "✅ 未启用"))
        } else {
            print("管理器沙盒：— （以裸二进制运行）")
        }
        return 0
    }

    private static func printUsage() {
        print("""
        微信多开 · 命令行

          doctor              环境体检（官方微信、lsregister、污染检查）
          list                列出全部实例及状态
          create [ID]         创建实例（不给 ID 则自动取最小可用编号）
          start ID            启动实例（经 LaunchServices，保证注入数据根）
          stop ID             退出实例（保留数据）
          rebuild ID          用当前官方版本重建实例 App（数据保留）
          rebuild-all         重建所有落后于官方版本的实例（微信升级后用）
          check [ID]          隔离自检（不给 ID 则检查全部）
          delete ID           删除实例及其数据
          version             显示管理器版本

        不带参数直接运行则进入菜单栏 App 模式。
        """)
    }

    enum CLIError: Error, LocalizedError {
        case noSuchInstance(String)
        case missingArgument(String)
        case instanceRunning(String)

        var errorDescription: String? {
            switch self {
            case .noSuchInstance(let id): return "没有编号为 " + id + " 的实例"
            case .missingArgument(let what): return "缺少参数：" + what
            case .instanceRunning(let id): return "实例 " + id + " 正在运行，请先退出"
            }
        }
    }
}
