import Foundation

/// config.json 的读写与编号分配。
enum InstanceStore {
    static func load() throws -> AppConfig {
        let url = Paths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder.iso.decode(AppConfig.self, from: data)
        guard config.schemaVersion <= 1 else { throw ConfigError.unsupportedSchema(config.schemaVersion) }
        return config
    }

    static func save(_ config: AppConfig) throws {
        try Paths.ensureSupportDirs()
        let data = try JSONEncoder.iso.encode(config)
        // 原子写，避免崩溃时留下半个文件。
        try data.write(to: Paths.configFile, options: .atomic)
    }

    /// 从未占用的编号里取最小的。删掉 02 后再建会复用 02。
    static func nextID(existing: [InstanceRecord]) -> String {
        let used = Set(existing.map(\.id))
        for n in 1...99 {
            let candidate = String(format: "%02d", n)
            if !used.contains(candidate) { return candidate }
        }
        return UUID().uuidString.prefix(4).description
    }

    /// 显示名由编号决定，唯一实现在 Paths.displayName(for:)。
    static func displayName(for id: String) -> String {
        Paths.displayName(for: id)
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
