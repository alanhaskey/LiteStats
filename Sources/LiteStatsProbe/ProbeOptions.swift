// 探针命令行参数解析（纯数据，不碰硬件）。
import Foundation

/// 参数错误（Result 的失败类型需要符合 Error）。
struct ProbeOptionError: Error {
    let message: String
}

struct ProbeOptions {
    var seconds: Double = 5
    var interval: Double = 1
    var json: Bool = false
    var help: Bool = false
    /// `--history-demo`：跑一段历史统计的端到端演示（见 HistoryDemo.swift），此时忽略 --interval。
    var historyDemo: Bool = false
    /// `--history-reset`：演示结束后调用 HistoryStore.resetAll()，把这次演示写的数据清掉。
    var historyReset: Bool = false
    /// 用户是否显式给过 --seconds（决定 --history-demo 要不要套用自己的默认值 10 秒）。
    var secondsSpecified: Bool = false

    static let usage = """
    用法: litestats-probe [--seconds N] [--interval S] [--json]
          litestats-probe --history-demo [--seconds N] [--history-reset]

      --seconds N    总采样时长（秒），默认 5（--history-demo 时默认 10）
      --interval S   采样间隔（秒），默认 1
      --json         每拍输出一行 JSON（JSONL）；汇总行写到 stderr
      --history-demo 历史统计端到端演示：每秒记录系统快照、每 2 秒记录按应用增量，
                     结束时打印 today() 汇总（网络总量 / CPU 秒数 / Top 5 应用）
                     与存储路径 / 体积，以及 record()/collector 的实测耗时
      --history-reset 仅配合 --history-demo：跑完调用 resetAll() 清空历史数据
      -h, --help     显示本帮助

    退出码: 0 正常（GPU/磁盘/温度失败只警告）; 1 参数错误; 2 CPU/内存/网络核心传感器失败
    """

    /// 解析参数。失败时返回错误描述（调用方打印用法并退出 1）。
    static func parse(_ arguments: [String]) -> Result<ProbeOptions, ProbeOptionError> {
        var options = ProbeOptions()
        var index = 1  // 跳过可执行文件路径
        while index < arguments.count {
            let raw = arguments[index]
            // 支持 --key=value 与 --key value 两种写法
            let (key, inlineValue) = split(raw)
            switch key {
            case "--seconds", "-s":
                guard let value = takeValue(inlineValue, arguments, &index) else {
                    return .failure(ProbeOptionError(message: "--seconds 需要一个数字"))
                }
                guard let seconds = Double(value), seconds > 0, seconds.isFinite else {
                    return .failure(ProbeOptionError(message: "--seconds 必须是 > 0 的数字，收到 '\(value)'"))
                }
                options.seconds = seconds
                options.secondsSpecified = true
            case "--interval", "-i":
                guard let value = takeValue(inlineValue, arguments, &index) else {
                    return .failure(ProbeOptionError(message: "--interval 需要一个数字"))
                }
                guard let interval = Double(value), interval > 0, interval.isFinite else {
                    return .failure(ProbeOptionError(message: "--interval 必须是 > 0 的数字，收到 '\(value)'"))
                }
                options.interval = interval
            case "--json":
                options.json = true
            case "--history-demo":
                options.historyDemo = true
            case "--history-reset":
                options.historyReset = true
            case "-h", "--help":
                options.help = true
            default:
                return .failure(ProbeOptionError(message: "未知参数 '\(raw)'"))
            }
            index += 1
        }
        // --history-demo 自己要跑 10 秒（除非用户显式指定了 --seconds）。
        if options.historyDemo && !options.secondsSpecified {
            options.seconds = 10
        }
        return .success(options)
    }

    private static func split(_ raw: String) -> (String, String?) {
        guard let range = raw.range(of: "="), raw.hasPrefix("-") else { return (raw, nil) }
        return (String(raw[raw.startIndex..<range.lowerBound]), String(raw[range.upperBound...]))
    }

    private static func takeValue(_ inline: String?, _ arguments: [String], _ index: inout Int) -> String? {
        if let inline { return inline }
        let next = index + 1
        guard next < arguments.count else { return nil }
        index = next
        return arguments[next]
    }
}
