import AppKit
import Foundation

// 入口分流：
//   无参数            → 菜单栏 App（正常形态）
//   create/list/check → CLI 模式，便于排障与自动化验证
//
// CLI 不只是调试用：菜单栏 App 万一被 Gatekeeper 拦住，CLI 是唯一还能跑通创建流程的入口。

let args = Array(CommandLine.arguments.dropFirst())

if let command = args.first, !command.hasPrefix("-") {
    exit(CLI.run(command: command, args: Array(args.dropFirst())))
}

// 纯 AppKit 启动，.accessory 模式：无 Dock 图标、无主窗口。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
