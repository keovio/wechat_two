import Foundation

/// APFS 写时复制克隆。1.4 GB 的微信实测 0.078 秒。
enum AppCloner {
    static func clone(from source: URL, to destination: URL) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            throw ClonerError.destinationExists(destination.path)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let rc = source.path.withCString { src in
            destination.path.withCString { dst in
                clonefile(src, dst, 0)
            }
        }
        guard rc == 0 else {
            throw ClonerError.clonefileFailed(errno: errno, path: destination.path)
        }
    }

    enum ClonerError: Error, LocalizedError {
        case destinationExists(String)
        case clonefileFailed(errno: Int32, path: String)
        var errorDescription: String? {
            switch self {
            case .destinationExists(let p): return "目标已存在：\(p)"
            case .clonefileFailed(let e, let p):
                return "clonefile 失败 (errno=\(e))：\(p)。若跨卷请检查磁盘格式是否为 APFS。"
            }
        }
    }
}
