import AppKit

/// 菜单栏控制器。菜单每次展开时重建，保证状态是最新的。
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var config = AppConfig()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill",
                               accessibilityDescription: "微信多开") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "微"
        }
        statusItem.button?.toolTip = "微信多开 " + AppInfo.version

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        reloadConfig()
    }

    private func reloadConfig() {
        do {
            config = try InstanceStore.load()
        } catch {
            Log.error("读取 config.json 失败：" + error.localizedDescription)
            config = AppConfig()
        }
    }

    // MARK: - 菜单构建

    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadConfig()
        menu.removeAllItems()

        let header = NSMenuItem(title: "微信多开 · 共 " + String(config.instances.count) + " 个实例", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if config.instances.isEmpty {
            let empty = NSMenuItem(title: "尚未创建实例", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        // 官方微信升级后，旧克隆体不会跟着升级 —— 在菜单顶部提醒并给出一键重建。
        let official = WeChatLocator.officialVersion()
        let outdated = outdatedInstances(official: official)
        if let official, !outdated.isEmpty {
            let notice = NSMenuItem(title: "⚠︎ 微信已更新到 " + official + "，" + String(outdated.count) + " 个实例待重建",
                                    action: nil, keyEquivalent: "")
            notice.isEnabled = false
            menu.addItem(notice)
            let rebuildAll = NSMenuItem(title: "全部重建（保留数据）…", action: #selector(rebuildOutdated), keyEquivalent: "")
            rebuildAll.target = self
            menu.addItem(rebuildAll)
            menu.addItem(.separator())
        }

        for record in config.instances {
            menu.addItem(instanceMenuItem(record, official: official))
        }

        if !config.instances.isEmpty {
            menu.addItem(.separator())
            let startAll = NSMenuItem(title: "全部启动", action: #selector(startAll), keyEquivalent: "")
            startAll.target = self
            menu.addItem(startAll)
            let stopAll = NSMenuItem(title: "全部退出", action: #selector(stopAll), keyEquivalent: "")
            stopAll.target = self
            menu.addItem(stopAll)
        }

        menu.addItem(.separator())

        let create = NSMenuItem(title: "新建实例…", action: #selector(createInstance), keyEquivalent: "n")
        create.target = self
        menu.addItem(create)

        let revealApps = NSMenuItem(title: "打开应用目录（~/Applications）", action: #selector(revealApps), keyEquivalent: "")
        revealApps.target = self
        menu.addItem(revealApps)

        let revealRoot = NSMenuItem(title: "打开数据目录", action: #selector(revealRoot), keyEquivalent: "")
        revealRoot.target = self
        menu.addItem(revealRoot)

        let revealLog = NSMenuItem(title: "查看运行日志", action: #selector(revealLog), keyEquivalent: "")
        revealLog.target = self
        menu.addItem(revealLog)

        menu.addItem(.separator())

        let login = NSMenuItem(title: LoginItem.needsApproval ? "登录时启动（待系统设置中允许）" : "登录时启动",
                               action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let about = NSMenuItem(title: "关于 微信多开 " + AppInfo.version, action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func instanceMenuItem(_ record: InstanceRecord, official: String?) -> NSMenuItem {
        let status = InstanceRuntime.status(of: record)
        var title = status.symbol + "  " + record.name
        if let official, official != record.sourceVersion {
            title += "  · 旧版 " + record.sourceVersion
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

        let sub = NSMenu()
        let infoApp = NSMenuItem(title: "实例 App：" + record.appPath, action: nil, keyEquivalent: "")
        infoApp.isEnabled = false
        sub.addItem(infoApp)
        let infoData = NSMenuItem(title: "数据根：" + record.homePath, action: nil, keyEquivalent: "")
        infoData.isEnabled = false
        sub.addItem(infoData)
        sub.addItem(.separator())

        if status == .running {
            let stop = NSMenuItem(title: "退出该实例", action: #selector(stopInstance(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = record
            sub.addItem(stop)
        } else {
            let start = NSMenuItem(title: "启动", action: #selector(startInstance(_:)), keyEquivalent: "")
            start.target = self
            start.representedObject = record
            start.isEnabled = status != .missing
            sub.addItem(start)
        }

        let check = NSMenuItem(title: "隔离自检", action: #selector(runSelfCheck(_:)), keyEquivalent: "")
        check.target = self
        check.representedObject = record
        sub.addItem(check)

        let openData = NSMenuItem(title: "在访达中打开数据根", action: #selector(openDataDir(_:)), keyEquivalent: "")
        openData.target = self
        openData.representedObject = record
        sub.addItem(openData)

        let revealApp = NSMenuItem(title: "在访达中显示实例 App（~/Applications）", action: #selector(revealApp(_:)), keyEquivalent: "")
        revealApp.target = self
        revealApp.representedObject = record
        sub.addItem(revealApp)

        sub.addItem(.separator())

        let rebuild = NSMenuItem(title: "用当前官方版本重建（保留数据）…", action: #selector(rebuildInstance(_:)), keyEquivalent: "")
        rebuild.target = self
        rebuild.representedObject = record
        sub.addItem(rebuild)

        let remove = NSMenuItem(title: "删除该实例…", action: #selector(removeInstance(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = record
        sub.addItem(remove)

        item.submenu = sub
        return item
    }

    // MARK: - 动作

    @objc private func createInstance() {
        let source: WeChatLocator.Info
        do {
            source = try WeChatLocator.locate()
        } catch {
            ProgressAlert.presentError(error)
            return
        }

        let nextID = InstanceStore.nextID(existing: config.instances)
        let name = InstanceStore.displayName(for: nextID)

        Log.info("开始创建实例 " + nextID + "（" + name + "）")

        // 自检要跑整包 codesign -v，同样放进后台，避免创建完成后菜单栏再卡一下。
        let summary = ProgressAlert.run(title: "正在创建「" + name + "」") { report in
            let result = try InstanceBuilder.create(id: nextID, source: source) { progress in
                report("步骤 " + String(progress.step) + "/" + String(progress.total) + " · " + progress.title)
            }
            report("隔离自检…")
            let failed = SelfCheck.check(record: result.record).filter { !$0.passed }
            return failed.map { $0.title + "：" + $0.detail }.joined(separator: "\n")
        }

        if let summary {
            Log.info("实例创建完成 " + nextID)
            let appPath = Paths.appBundle(nextID).path
            if summary.isEmpty {
                ProgressAlert.info("「" + name + "」创建完成",
                                   detail: "7 项隔离自检全部通过。\n\n已放入 " + appPath + "，可在启动台 / Spotlight 搜到，也可从 Dock 双击启动。")
            } else {
                ProgressAlert.info("「" + name + "」创建完成，但有自检项未通过", detail: summary)
            }
        }
        reloadConfig()
    }

    /// 把可能耗时数秒的操作（LaunchServices 握手、等待进程退出、pgrep）挪出主线程，
    /// 菜单栏始终可响应；出错时回到主线程弹窗。
    private func inBackground(_ work: @escaping () throws -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
            } catch {
                DispatchQueue.main.async { ProgressAlert.presentError(error) }
            }
        }
    }

    @objc private func startInstance(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        inBackground {
            try InstanceRuntime.start(record)
            Log.info("已启动 " + record.name)
        }
    }

    @objc private func stopInstance(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        inBackground {
            try InstanceRuntime.stop(record)
            Log.info("已退出 " + record.name)
        }
    }

    @objc private func runSelfCheck(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        let text = ProgressAlert.run(title: record.name + " · 隔离自检中…") { _ in
            SelfCheck.check(record: record)
                .map { $0.symbol + "  " + $0.title + "\n      " + $0.detail }
                .joined(separator: "\n")
        }
        if let text {
            ProgressAlert.info(record.name + " · 隔离自检", detail: text)
        }
    }

    @objc private func openDataDir(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: record.homePath))
    }

    @objc private func revealApp(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.appPath)])
    }

    @objc private func rebuildInstance(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }

        let confirm = NSAlert()
        confirm.messageText = "用当前官方微信重建「" + record.name + "」？"
        confirm.informativeText = "登录态与聊天记录保存在独立的 home/ 目录中，重建不会丢失。"
        confirm.addButton(withTitle: "重建")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let source: WeChatLocator.Info
        do {
            source = try WeChatLocator.locate()
        } catch {
            ProgressAlert.presentError(error)
            return
        }

        let ok = ProgressAlert.run(title: "正在重建「" + record.name + "」") { report in
            // 运行中的实例持有 home/ 里的文件句柄，必须先退出再挪动数据目录。
            if InstanceRuntime.status(of: record) == .running {
                report("正在退出运行中的实例…")
                try InstanceRuntime.stop(record)
            }
            let result = try InstanceBuilder.rebuild(id: record.id, source: source) { progress in
                report("步骤 " + String(progress.step) + "/" + String(progress.total) + " · " + progress.title)
            }
            return result.record.bundleID
        }

        if ok != nil {
            ProgressAlert.info("「" + record.name + "」已重建", detail: "版本 " + source.version + "，数据目录保持 " + record.homePath)
        }
        reloadConfig()
    }

    @objc private func removeInstance(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "删除「" + record.name + "」？"
        confirm.informativeText = "这会删掉实例 App 和它的全部本地数据（含聊天记录）。官方微信不受影响。"
        confirm.addButton(withTitle: "删除")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        _ = ProgressAlert.run(title: "正在删除「" + record.name + "」") { report in
            if InstanceRuntime.status(of: record) == .running {
                report("正在退出实例…")
                do { try InstanceRuntime.stop(record) } catch { Log.warn("停止实例失败：" + error.localizedDescription) }
            }
            report("正在删除文件…")
            try InstanceBuilder.delete(id: record.id, removeData: true)
            Log.info("已删除实例 " + record.name)
            return ""
        }
        reloadConfig()
    }

    private func outdatedInstances(official: String?) -> [InstanceRecord] {
        guard let official else { return [] }
        return config.instances.filter { $0.sourceVersion != official
            && FileManager.default.fileExists(atPath: $0.appPath) }
    }

    @objc private func rebuildOutdated() {
        let targets = outdatedInstances(official: WeChatLocator.officialVersion())
        guard !targets.isEmpty else { return }

        let confirm = NSAlert()
        confirm.messageText = "用新版官方微信重建 " + String(targets.count) + " 个实例？"
        confirm.informativeText = "运行中的实例会先被退出。登录态与聊天记录保存在独立的数据目录中，不会丢失。"
        confirm.addButton(withTitle: "全部重建")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let source: WeChatLocator.Info
        do {
            source = try WeChatLocator.locate()
        } catch {
            ProgressAlert.presentError(error)
            return
        }

        let done = ProgressAlert.run(title: "正在重建 " + String(targets.count) + " 个实例") { report in
            var names: [String] = []
            for record in targets {
                if InstanceRuntime.status(of: record) == .running {
                    report(record.name + " · 正在退出…")
                    try InstanceRuntime.stop(record)
                }
                _ = try InstanceBuilder.rebuild(id: record.id, source: source) { progress in
                    report(record.name + " · 步骤 " + String(progress.step) + "/" + String(progress.total) + " · " + progress.title)
                }
                names.append(record.name)
            }
            return names.joined(separator: "、")
        }

        if let names = done {
            ProgressAlert.info("已重建到 " + source.version, detail: names)
        }
        reloadConfig()
    }

    @objc private func startAll() {
        let targets = config.instances.filter { InstanceRuntime.status(of: $0) == .stopped }
        guard !targets.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            for record in targets {
                do { try InstanceRuntime.start(record) } catch { errors.append(record.name + "：" + error.localizedDescription) }
            }
            if !errors.isEmpty {
                DispatchQueue.main.async {
                    ProgressAlert.info("部分实例启动失败", detail: errors.joined(separator: "\n"))
                }
            }
        }
    }

    @objc private func stopAll() {
        let running = config.instances.filter { InstanceRuntime.status(of: $0) == .running }
        guard !running.isEmpty else { return }
        _ = ProgressAlert.run(title: "正在退出 " + String(running.count) + " 个实例") { report in
            for record in running {
                report("正在退出 " + record.name + "…")
                try InstanceRuntime.stop(record)
            }
            return ""
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
            if LoginItem.needsApproval {
                ProgressAlert.info("还差一步", detail: "请在「系统设置 → 通用 → 登录项」里允许「微信多开」。")
                LoginItem.openSystemSettings()
            }
        } catch {
            ProgressAlert.presentError(error)
        }
    }

    @objc private func revealApps() {
        NSWorkspace.shared.open(Paths.appsDir)
    }

    @objc private func revealRoot() {
        NSWorkspace.shared.open(Paths.supportRoot)
    }

    @objc private func revealLog() {
        let log = Paths.logsDir.appendingPathComponent("wechatmulti.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(Paths.logsDir)
        }
    }
}
