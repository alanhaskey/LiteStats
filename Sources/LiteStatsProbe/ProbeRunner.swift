// 探针调度与汇总（main.swift 只做参数解析和调用这里）。
import Foundation
import LiteStatsCore

/// 采样健康度统计：用来判断该不该以非 0 退出。
struct ProbeSummary {
    var samples = 0
    var totalMs = 0.0
    var maxMs = 0.0
    var cpuOK = 0
    var memOK = 0
    var netOK = 0
    var gpuOK = 0
    var diskOK = 0
    /// 温度读数成功（sourceDescription != nil）/ 至少读到 1 个风扇的拍数。
    var thermalOK = 0
    var fanOK = 0
    /// 单次温度 + 风扇读取耗时的最大值（毫秒）。
    var maxThermalReadMs = 0.0

    mutating func record(_ snapshot: SystemSnapshot, sampleMs: Double) {
        samples += 1
        totalMs += sampleMs
        maxMs = max(maxMs, sampleMs)

        // 判据只看公开快照（Core 的公开接口已冻结，不额外暴露健康状态）：
        // CPU：coreCount > 0 且 perCore 长度与之一致；失败时 Core 会返回 coreCount = 0。
        if snapshot.cpu.coreCount > 0, snapshot.cpu.perCore.count == snapshot.cpu.coreCount {
            cpuOK += 1
        }
        if snapshot.memory.total > 0, snapshot.memory.used > 0 { memOK += 1 }
        if snapshot.network.interfaceName != nil { netOK += 1 }
        if snapshot.gpu.utilization != nil { gpuOK += 1 }
        if snapshot.disk != nil { diskOK += 1 }
        if snapshot.thermal.sourceDescription != nil { thermalOK += 1 }
        if !snapshot.thermal.fans.isEmpty { fanOK += 1 }
        maxThermalReadMs = max(maxThermalReadMs, snapshot.thermal.readMillis)
    }

    /// CPU / 内存 / 网络是核心传感器：任何一个整轮都没成功 → 退出码 2。
    /// GPU / 磁盘 / 温度失败只算警告，仍返回 0。
    var exitCode: Int32 {
        guard samples > 0 else { return 2 }
        if cpuOK == 0 || memOK == 0 || netOK == 0 { return 2 }
        return 0
    }

    func summaryLine(duration: TimeInterval) -> String {
        let avg = samples > 0 ? totalMs / Double(samples) : 0
        func status(_ ok: Int) -> String {
            "\(ok > 0 ? "ok" : "FAIL")(\(ok)/\(samples))"
        }
        return String(format: "[summary] samples=%d avgSampleMs=%.3f maxSampleMs=%.3f "
                      + "cpu=%@ mem=%@ net=%@ gpu=%@ disk=%@ duration=%.2fs "
                      + "thermal=%@ fan=%@ maxThermalReadMs=%.3f",
                      samples, avg, maxMs,
                      status(cpuOK), status(memOK), status(netOK), status(gpuOK), status(diskOK),
                      duration,
                      status(thermalOK), status(fanOK), maxThermalReadMs)
    }
}

enum ProbeRunner {
    /// 采样上限：防止有人传 --interval 0.0001 --seconds 100 把机器跑死。
    private static let maxSamples = 200_000

    static func run(_ options: ProbeOptions) -> Int32 {
        let monitor = SystemMonitor()
        let reporter = ProbeReporter(json: options.json)
        reporter.emitHeader(options: options, coreCount: monitor.coreCount)

        var summary = ProbeSummary()
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start &+ UInt64(options.seconds * 1_000_000_000)
        let intervalNanos = max(UInt64(options.interval * 1_000_000_000), 1)
        var next = start
        var capped = false

        while next <= deadline {
            let begin = DispatchTime.now().uptimeNanoseconds
            let snapshot = monitor.sample()
            let end = DispatchTime.now().uptimeNanoseconds
            let sampleMs = Double(end - begin) / 1_000_000

            reporter.emit(snapshot: snapshot, sampleMs: sampleMs)
            summary.record(snapshot, sampleMs: sampleMs)

            if summary.samples >= maxSamples {
                capped = true
                break
            }

            next = next &+ intervalNanos
            if next > deadline { break }
            let now = DispatchTime.now().uptimeNanoseconds
            if next > now {
                Thread.sleep(forTimeInterval: Double(next - now) / 1_000_000_000)
            }
        }

        let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        reporter.emitSummary(summary.summaryLine(duration: duration))

        if summary.gpuOK == 0 {
            reporter.emitError("[warn] GPU 利用率取不到（utilization = nil）："
                               + "UI 会显示 n/a，不影响退出码")
        }
        if summary.diskOK == 0 {
            reporter.emitError("[warn] 磁盘占用取不到（disk = nil）：不影响退出码")
        }
        if summary.thermalOK == 0 {
            reporter.emitError("[warn] 温度取不到（thermal = .unavailable）："
                               + "UI 应显示 n/a，不影响退出码")
        }
        if summary.fanOK == 0 {
            reporter.emitError("[warn] 风扇转速取不到（fans 为空）："
                               + "可能是无风扇机型，不影响退出码")
        }
        if capped {
            reporter.emitError("[warn] 达到采样上限 \(maxSamples) 拍，提前结束")
        }
        return summary.exitCode
    }
}
