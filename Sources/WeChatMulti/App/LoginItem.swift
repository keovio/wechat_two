import Foundation
import ServiceManagement

/// 登录时自动启动管理器（SMAppService，macOS 13+ 官方 API）。
///
/// ad-hoc 签名的 App 注册后，系统可能要求用户在
/// 「系统设置 → 通用 → 登录项」里手动允许一次，此时状态为 requiresApproval。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// 管理器自身的版本信息（来自 Info.plist，CI 打包时写入）。
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
