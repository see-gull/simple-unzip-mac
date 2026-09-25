import Foundation

/// Errors surfaced by the 7-Zip engine layer.
public enum ArchiveError: Error, LocalizedError, Equatable {
    /// No usable `7zz` executable could be found.
    case toolNotFound(searched: [String])
    /// The child process could not be spawned.
    case launchFailed(String)
    /// `7zz` exited with a non-zero status.
    case commandFailed(exitCode: Int32, messages: [String])
    /// The operation was cancelled by the user.
    case cancelled
    /// Output from `7zz` could not be interpreted.
    case parseFailed(String)
    /// `7zz` reported a wrong or missing password.
    case wrongPassword(messages: [String])

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let searched):
            return "找不到 7zz 可执行文件。已查找位置：\n" + searched.joined(separator: "\n")
        case .launchFailed(let reason):
            return "无法启动 7zz 进程：\(reason)"
        case .commandFailed(let code, let messages):
            let detail = messages.isEmpty ? "7zz 未提供更多信息。" : messages.joined(separator: "\n")
            return "7zz 执行失败（退出码 \(code)）：\n\(detail)"
        case .cancelled:
            return "操作已取消。"
        case .parseFailed(let reason):
            return "无法解析 7zz 输出：\(reason)"
        case .wrongPassword(let messages):
            let detail = messages.isEmpty ? "" : "\n" + messages.joined(separator: "\n")
            return "密码错误或压缩包已加密，需要正确密码。\(detail)"
        }
    }

    /// A short, user-facing summary suitable for a task row.
    public var shortDescription: String {
        switch self {
        case .toolNotFound: return "找不到 7zz"
        case .launchFailed: return "无法启动 7zz"
        case .commandFailed(let code, _): return "7zz 失败（退出码 \(code)）"
        case .cancelled: return "已取消"
        case .parseFailed: return "输出解析失败"
        case .wrongPassword: return "密码错误"
        }
    }
}

/// Recognises the message shapes `7zz` uses for password problems.
enum MessageClassifier {
    static func isPasswordProblem(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("wrong password")
            || lowered.contains("data error in encrypted file")
            || lowered.contains("cannot open encrypted archive")
            || lowered.contains("enter password")
    }

    static func isError(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.hasPrefix("error:")
            || lowered.contains("error:")
            || lowered.contains("cannot open")
            || lowered.contains("is not supported")
            || lowered.contains("no such file")
    }
}
