import Foundation

/// 极简日志：同时写 stderr 与 ~/Library/Application Support/WeChatMulti/logs/。
/// 自用工具，不需要 os_log 的复杂度，但必须能事后排查失败原因。
enum Log {
    private static let queue = DispatchQueue(label: "com.local.wechatmulti.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ msg: String) { write("INFO ", msg) }
    static func warn(_ msg: String) { write("WARN ", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "[\(stamp.string(from: Date()))] \(level) \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            try? FileManager.default.createDirectory(at: Paths.logsDir, withIntermediateDirectories: true)
            let url = Paths.logsDir.appendingPathComponent("wechatmulti.log")
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(Data(line.utf8))
                try? fh.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
