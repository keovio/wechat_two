import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("WeChatMulti 启动，支持目录 " + Paths.supportRoot.path)
        do {
            try Paths.ensureSupportDirs()
        } catch {
            Log.error("创建支持目录失败：" + error.localizedDescription)
        }
        controller = StatusItemController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("WeChatMulti 退出")
    }

    /// 菜单栏 App 关掉最后一个窗口也不退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
