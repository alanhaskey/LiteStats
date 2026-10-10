import AppKit

/// 轻量诊断日志（`--trace <path>` 打开）。
///
/// 用途：本机没有屏幕录制权限，无法看画面；把状态机切换与鼠标位置写进文件后，
/// 就可以用脚本移动光标来端到端验证"悬浮刘海 → 展开 → 移开 → 收起"整条链路。
enum Trace {
    nonisolated(unsafe) private static var logPath: String?
    private static let lock = NSLock()

    static func enableIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--trace"), index + 1 < args.count else { return }
        logPath = args[index + 1]
        log("trace 启动 pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    static var isEnabled: Bool { logPath != nil }

    static func log(_ message: String) {
        guard let path = logPath else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, message)
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
