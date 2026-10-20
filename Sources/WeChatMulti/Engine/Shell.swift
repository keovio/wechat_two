import Foundation

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
}

enum ShellError: Error, LocalizedError {
    case launchFailed(String, Error)
    case failed(command: String, code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let e):
            return "无法启动 \(path)：\(e.localizedDescription)"
        case .failed(let cmd, let code, let err):
            let tail = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "命令失败(exit=\(code))：\(cmd)" + (tail.isEmpty ? "" : "\n\(tail.suffix(800))")
        }
    }
}

/// 外部命令调用。codesign / lsregister 等都从这里走，便于统一记录与报错。
enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], allowFailure: Bool = false) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            throw ShellError.launchFailed(launchPath, error)
        }

        // stdout / stderr 必须**并发**读完再 wait：
        // 串行读时，若子进程先把 stderr 的 64KB 管道缓冲写满（codesign -v 很容易），
        // 它会阻塞在 write 上，而我们阻塞在读 stdout 的 EOF 上 —— 双方互等，死锁。
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        p.waitUntilExit()

        let result = ShellResult(
            exitCode: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )

        if !result.ok && !allowFailure {
            let cmd = ([launchPath] + args).joined(separator: " ")
            throw ShellError.failed(command: cmd, code: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}
