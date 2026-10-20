import AppKit

/// 创建实例要跑 11 步流水线（克隆 + 253 个 Mach-O 重签，约 3-6 秒），
/// 用一个模态进度窗把用户挡在外面，避免重复点击导致并发写同一个目录。
enum ProgressAlert {
    static func run(title: String, body: @escaping (_ report: @escaping (String) -> Void) throws -> String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "正在准备…"
        alert.alertStyle = .informational

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        spinner.startAnimation(nil)
        alert.accessoryView = spinner

        alert.addButton(withTitle: "取消")
        alert.buttons[0].isEnabled = false

        var result: String?
        var thrown: Error?

        // NSAlert.runModal 会占用主线程，因此后台跑流水线、主线程收进度。
        DispatchQueue.global().async {
            do {
                let value = try body { message in
                    DispatchQueue.main.async { alert.informativeText = message }
                }
                result = value
                DispatchQueue.main.async { NSApp.stopModal(withCode: .OK) }
            } catch {
                thrown = error
                DispatchQueue.main.async { NSApp.stopModal(withCode: .cancel) }
            }
        }

        _ = alert.runModal()

        if let e = thrown { presentError(e); return nil }
        return result
    }

    static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    static func info(_ text: String, detail: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = text
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
