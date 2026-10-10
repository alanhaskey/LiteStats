// 按进程网络流量：调用 `/usr/bin/nettop`。
//
// 为什么用 nettop：
//   * macOS 没有公开的"按进程网络计数"API（NetworkStatistics.framework 是私有的，
//     `nstat` 只给总量，`getifaddrs` 只给网卡总量）；
//   * nettop 走 NetworkStatistics，输出每个进程的**自进程启动以来的累计** bytes_in / bytes_out；
//   * 实测一次调用 10 ms 左右、输出 37 行左右，不需要 root。
//
// ⚠️ 关键语义：nettop 给的是**累计值**（不是增量）。
//    相隔几秒采两次，空闲进程的数值一动不动、活跃进程的数值在涨 —— 所以只能"差分"出增量。
//    这也意味着：**第一次采样只能拿来建基线**，它本身给不出任何增量。
//
// 命令行：`nettop -P -x -l 1 -J bytes_in,bytes_out -n`
//   -P  per-process；-x 人类不可读的紧凑输出；-l 1 采 1 次就退出；
//   -J  只要这两列；-n  不做反查（快）。
import Foundation

/// nettop 输出里的一行（累计值）。
struct NettopProcessCounters: Equatable {
    let name: String
    let pid: Int32
    let bytesIn: UInt64
    let bytesOut: UInt64
}

enum NettopParser {
    /// 纯函数解析（不碰系统，方便单测）。
    ///
    /// 每行长这样（名字里可能带空格 / 括号 / 点，所以**不能**简单按 "." 或空白切分）：
    /// ```
    /// mDNSResponder.684    80222534    68297149
    /// OrbStack Helper.1336  3258443      544716
    /// WeChatAppEx Hel.7914     6137        4953
    /// ```
    /// 解析策略：整行按空白切成 token 后，**从右往左**取两个整数，剩下的全部拼回 label；
    /// label 里**最后一个 "." 之后**才是 PID（进程名本身可能含点，例如 "com.apple.WebKit"）。
    static func parse(_ output: String) -> [NettopProcessCounters] {
        var result: [NettopProcessCounters] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = parseLine(String(rawLine)) { result.append(entry) }
        }
        return result
    }

    /// 解析单行；不是数据行（表头 / 提示）时返回 nil。
    static func parseLine(_ line: String) -> NettopProcessCounters? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // 至少要有 "名字.PID" + bytes_in + bytes_out 三个 token
        guard tokens.count >= 3 else { return nil }
        guard let bytesOut = UInt64(tokens[tokens.count - 1]),
              let bytesIn = UInt64(tokens[tokens.count - 2]) else { return nil }

        // 表头 "bytes_in bytes_out" 会在上面两步被挡掉；这里再挡一次纯数字行。
        let label = tokens[0..<(tokens.count - 2)].joined(separator: " ")
        guard let dot = label.lastIndex(of: ".") else { return nil }
        let pidText = label[label.index(after: dot)...]
        // kernel_task 的 PID 就是 0，所以下界是 >= 0 而不是 > 0。
        guard let pid = Int32(pidText), pid >= 0 else { return nil }
        let name = String(label[label.startIndex..<dot])
        guard !name.isEmpty else { return nil }
        return NettopProcessCounters(name: name, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut)
    }
}

enum NettopSampler {
    /// nettop 的绝对路径。macOS 上它一定在 /usr/bin 下，不依赖 PATH。
    static let defaultExecutable = "/usr/bin/nettop"

    /// 跑一次 nettop 并解析。任何失败（文件不存在 / 启动失败 / 输出不可解析）都返回空数组，
    /// 由调用方降级成"只有 CPU / 内存"，绝不抛错。
    ///
    /// ⚠️ 这里**故意不调用 `waitUntilExit()`**：本机实测（CLT-only 环境）
    /// `Process.waitUntilExit()` 即使对 `/bin/echo` 也要 ~67 ms（Foundation 的等待实现带轮询），
    /// 而 nettop 在 ~13 ms 就把 stdout 写完并关闭了。设一个空的 terminationHandler
    /// 让 Foundation 继续异步回收子进程即可 —— 实测连跑 20 次后进程表里 0 个 nettop 残留（无僵尸）。
    /// 结果：单次采样从 ~80 ms 降到 ~13 ms。
    static func sample(executable: String = defaultExecutable) -> [NettopProcessCounters] {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-P", "-x", "-l", "1", "-J", "bytes_in,bytes_out", "-n"]
        let stdout = Pipe()
        process.standardOutput = stdout
        // stderr 直接丢黑洞：接管道又没人读的话，输出一多就会把子进程堵死。
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }

        do {
            try process.run()
        } catch {
            return []
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return NettopParser.parse(String(decoding: data, as: UTF8.self))
    }
}
