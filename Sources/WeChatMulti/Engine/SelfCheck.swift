import Foundation

/// 隔离自检 —— 这是产品里最重要的一段代码。
///
/// 产品最大的失败模式不是"起不来"，而是"看起来起来了，数据却写进了真实 ~/Documents"。
/// 所以每次创建后、每次启动前都要能回答："这个实例的数据根真的被钉住了吗？"
enum SelfCheck {
    struct Item {
        let title: String
        let passed: Bool
        let detail: String

        var symbol: String { passed ? "✅" : "❌" }
    }

    static func check(record: InstanceRecord) -> [Item] {
        var items: [Item] = []
        let fm = FileManager.default

        // 1) App 存在
        let appExists = fm.fileExists(atPath: record.appPath)
        items.append(Item(title: "实例文件存在", passed: appExists, detail: appExists ? record.appPath : "缺失"))

        // 2) LSEnvironment 已注入且指向本实例的 home
        let injected = EnvInjector.injectedHome(app: URL(fileURLWithPath: record.appPath))
        let injectOK = injected == record.homePath
        items.append(Item(
            title: "数据根已钉住",
            passed: injectOK,
            detail: injectOK ? injected! : "实际为 " + (injected ?? "未设置") + "，期望 " + record.homePath
        ))

        // 3) bundle id 已改写（不等于官方 id 即算通过）
        let plistURL = URL(fileURLWithPath: record.appPath).appendingPathComponent("Contents/Info.plist")
        var actualID = ""
        if let data = try? Data(contentsOf: plistURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            actualID = dict["CFBundleIdentifier"] as? String ?? ""
        }
        let idOK = !actualID.isEmpty && actualID != "com.tencent.xinWeChat"
        items.append(Item(title: "身份已隔离", passed: idOK, detail: actualID))

        // 4) 自更新已禁用
        var hasSUKey = false
        if let data = try? Data(contentsOf: plistURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            hasSUKey = dict["SUPublicEDKey"] != nil || dict["SUEnableInstallerLauncherService"] != nil
        }
        items.append(Item(title: "自更新已禁用", passed: !hasSUKey, detail: hasSUKey ? "仍含 Sparkle 键" : "已移除"))

        // 5) 签名有效
        let verify = Resigner.verify(app: URL(fileURLWithPath: record.appPath))
        items.append(Item(title: "签名有效", passed: verify.ok, detail: verify.detail))

        // 6) 官方微信未被改动 —— 全局性检查，放这里是为了创建后立刻可见
        let team = WeChatLocator.codesignTeamID(at: WeChatLocator.officialPath.appendingPathComponent("Contents/MacOS/WeChat"))
        let officialOK = team == "5A4RE8SF68"
        items.append(Item(title: "官方微信未被改动", passed: officialOK, detail: "TeamIdentifier=" + (team ?? "nil")))

        // 7) 真实目录零污染
        let realAppData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/app_data")
        let realFiles = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/xwechat_files")
        let polluted = fm.fileExists(atPath: realAppData.path) || fm.fileExists(atPath: realFiles.path)
        items.append(Item(
            title: "真实 ~/Documents 零污染",
            passed: !polluted,
            detail: polluted ? "发现 ~/Documents/app_data 或 xwechat_files" : "干净"
        ))

        return items
    }
}
