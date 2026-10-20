import Foundation

/// 一个受管实例的持久化记录。config.json 里存的就是它的数组。
struct InstanceRecord: Codable, Identifiable, Equatable {
    /// "01" / "02" …… 目录名、bundle id 后缀、显示序号都来自它。
    var id: String
    /// "微信 2" 这类人类可读名称。
    var name: String
    /// 克隆时官方微信的版本，用于提示重建。
    var sourceVersion: String
    var bundleID: String
    var createdAt: Date

    /// 克隆体在 ~/Applications 下的位置（启动台/Dock 能看到的就是它）。
    var appPath: String { Paths.appBundle(id).path }
    /// CFFIXED_USER_HOME 指向的数据根，在 Application Support 下。
    var homePath: String { Paths.home(id).path }
}

/// 顶层配置。
struct AppConfig: Codable {
    var schemaVersion: Int = 1
    var instances: [InstanceRecord] = []
}

enum ConfigError: Error, LocalizedError {
    case unsupportedSchema(Int)
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v): return "配置版本 \(v) 高于本程序支持的版本，拒绝加载以免损坏数据。"
        }
    }
}
