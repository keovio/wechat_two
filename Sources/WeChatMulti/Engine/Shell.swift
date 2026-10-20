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

        // 先读完管道再 wait，避免大输出把子进程堵死。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
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
