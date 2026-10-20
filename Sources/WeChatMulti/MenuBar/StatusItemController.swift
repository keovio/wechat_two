import AppKit

/// 菜单栏控制器。菜单每次展开时重建，保证状态是最新的。
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var config = AppConfig()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = "微"
        statusItem.button?.toolTip = "微信多开"

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

        for record in config.instances {
            menu.addItem(instanceMenuItem(record))
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

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func instanceMenuItem(_ record: InstanceRecord) -> NSMenuItem {
        let status = InstanceRuntime.status(of: record)
        let item = NSMenuItem(title: status.symbol + "  " + record.name, action: nil, keyEquivalent: "")

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

        let outcome = ProgressAlert.run(title: "正在创建「" + name + "」") { report in
            let result = try InstanceBuilder.create(id: nextID, source: source) { progress in
                report("步骤 " + String(progress.step) + "/" + String(progress.total) + " · " + progress.title)
            }
            return result.record.bundleID
        }

        if let bundleID = outcome {
            Log.info("实例创建完成 " + bundleID)
            // 创建后立刻自检一次，把"数据根是否钉住"这件事当场说清楚。
            if let record = (try? InstanceStore.load())?.instances.first(where: { $0.id == nextID }) {
                let items = SelfCheck.check(record: record)
                let failed = items.filter { !$0.passed }
                if failed.isEmpty {
                    ProgressAlert.info("「" + record.name + "」创建完成", detail: "7 项隔离自检全部通过。\n\n已放入 " + record.appPath + "，可在启动台 / Spotlight 搜到，也可从 Dock 双击启动。")
                } else {
                    ProgressAlert.info("「" + record.name + "」创建完成，但有 " + String(failed.count) + " 项自检未通过",
                                       detail: failed.map { $0.title + "：" + $0.detail }.joined(separator: "\n"))
                }
            }
        }
        reloadConfig()
    }

    @objc private func startInstance(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        do {
            try InstanceRuntime.start(record)
            Log.info("已启动 " + record.name)
        } catch {
            ProgressAlert.presentError(error)
        }
    }

    @objc private func stopInstance(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        do {
            try InstanceRuntime.stop(record)
            Log.info("已退出 " + record.name)
        } catch {
            ProgressAlert.presentError(error)
        }
    }

    @objc private func runSelfCheck(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? InstanceRecord else { return }
        let items = SelfCheck.check(record: record)
        let lines = items.map { $0.symbol + "  " + $0.title + "\n      " + $0.detail }
        ProgressAlert.info(record.name + " · 隔离自检", detail: lines.joined(separator: "\n"))
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

        if InstanceRuntime.status(of: record) == .running {
            do { try InstanceRuntime.stop(record) } catch { Log.warn("停止实例失败：" + error.localizedDescription) }
        }

        do {
            try InstanceBuilder.delete(id: record.id, removeData: true)
            Log.info("已删除实例 " + record.name)
        } catch {
            ProgressAlert.presentError(error)
        }
        reloadConfig()
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
