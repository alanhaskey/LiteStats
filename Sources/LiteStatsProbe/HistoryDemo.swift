// `litestats-probe --history-demo`：历史统计的端到端演示 + 开销实测。
//
// 做的事：
//   1. 每秒 `HistoryStore.record(snapshot:)`，每 2 秒 `record(appSamples:)`（间隔 = 2s）；
//   2. 顺手测 `record()` 与 `AppUsageCollector.sample()` 的真实耗时；
//   3. 结束时打印 `today()` 的汇总：网络总量、CPU 秒数、Top 5 应用、存储路径 / 体积。
//
// 它写的是**真实**的默认目录（~/Library/Application Support/LiteStats/History），
// 这样"跑完能看到真实文件、真实 Top 应用"才算端到端验证；
// 加 `--history-reset` 可以在跑完后调用 `resetAll()` 把这次演示的数据清掉。
import Foundation
import LiteStatsCore

enum HistoryDemo {

    static func run(_ options: ProbeOptions) -> Int32 {
        let seconds = max(options.seconds, 1)
        let monitor = SystemMonitor()
        // 演示只有十几秒，nettop 跑勤一点才能在这么短的窗口里看到网络增量。
        let collector = AppUsageCollector(nettopEveryNSamples: 2)

        let store: HistoryStore
        do {
            // 默认写 ~/Library/Application Support/LiteStats（真实使用路径）。
            // 允许用环境变量覆盖，方便在受限沙箱 / CI 里把数据写进工作目录：
            //   LITESTATS_HISTORY_DIR="$PWD/.history-demo" litestats-probe --history-demo
            let override = ProcessInfo.processInfo.environment["LITESTATS_HISTORY_DIR"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            store = try HistoryStore(directory: override)
        } catch {
            FileHandle.standardError.write(Data(("无法初始化 HistoryStore：\(error)\n").utf8))
            return 1
        }

        print("[history-demo] 时长 \(Int(seconds))s：每 1s record(snapshot:)，每 2s record(appSamples:)"
              + "，nettopEveryNSamples=2")
        print("[history-demo] 存储目录 \(store.storagePath)")
        print("[history-demo] 起始体积 \(store.storageBytes) 字节")

        var recordTotal = 0.0, recordMax = 0.0, recordCount = 0
        var appRecordTotal = 0.0, appRecordMax = 0.0, appRecordCount = 0
        var collectorTotal = 0.0, collectorMax = 0.0, collectorSamples = 0
        var batchesWithNetwork = 0
        var maxAppsInBatch = 0

        let start = Date()
        var tick = 0
        while Date().timeIntervalSince(start) < seconds {
            // 1) 系统快照
            let snapshot = monitor.sample()
            let begin = DispatchTime.now().uptimeNanoseconds
            store.record(snapshot: snapshot, interval: 1)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
            recordTotal += elapsed
            recordMax = max(recordMax, elapsed)
            recordCount += 1

            // 2) 按应用（每 2 秒）
            if tick % 2 == 0 {
                let collectBegin = DispatchTime.now().uptimeNanoseconds
                let samples = collector.sample()
                let collectorMs = Double(DispatchTime.now().uptimeNanoseconds - collectBegin) / 1_000_000
                collectorTotal += collectorMs
                collectorMax = max(collectorMax, collectorMs)
                collectorSamples += 1
                maxAppsInBatch = max(maxAppsInBatch, samples.count)
                if samples.contains(where: { $0.networkIn > 0 || $0.networkOut > 0 }) {
                    batchesWithNetwork += 1
                }

                let appBegin = DispatchTime.now().uptimeNanoseconds
                store.record(appSamples: samples, interval: 2)
                let appMs = Double(DispatchTime.now().uptimeNanoseconds - appBegin) / 1_000_000
                appRecordTotal += appMs
                appRecordMax = max(appRecordMax, appMs)
                appRecordCount += 1

                print(String(format: "[history-demo] t=%4.1fs apps=%3d（有网络增量=%d）"
                             + " collector=%.2fms record(apps)=%.3fms",
                             Date().timeIntervalSince(start), samples.count,
                             samples.filter { $0.networkIn > 0 || $0.networkOut > 0 }.count,
                             collectorMs, appMs))
            }

            tick += 1
            Thread.sleep(forTimeInterval: 1)
        }

        // ---- 汇总 ----
        let summary = store.today()
        let coreCount = monitor.coreCount
        print("")
        print("[history-demo] today() 汇总：快照拍数=\(recordCount) 核心数=\(coreCount)")
        print(String(format: "[history-demo] 网络 ↓%@ ↑%@ 合计 %@   CPU %.3f 秒   记录时长 %.1f 秒   平均 CPU %.2f%%",
                     formatBytes(Double(summary.networkIn)), formatBytes(Double(summary.networkOut)),
                     formatBytes(Double(summary.networkTotal)), summary.cpuSeconds,
                     summary.trackDuration, summary.averageCPUUsage(coreCount: coreCount) * 100))
        print(String(format: "[history-demo] GPU 积分 %.3f 秒   平均内存 %@   小时桶 %d 个   应用 %d 个",
                     summary.gpuSeconds, formatBytes(summary.memoryBytesAverage),
                     summary.hourly.count, summary.apps.count))
        for bucket in summary.hourly.suffix(2) {
            print(String(format: "[history-demo] 小时桶 %@  cpu=%.3fs gpu=%.1f%% ↓%@ ↑%@ samples=%d",
                         Self.timeFormatter.string(from: bucket.hourStart),
                         bucket.cpuSeconds, bucket.gpuPercentAverage * 100,
                         formatBytes(Double(bucket.networkIn)), formatBytes(Double(bucket.networkOut)),
                         bucket.sampleCount))
        }

        print("[history-demo] Top 5 应用（影响权重 = 网络总字节 + CPU 秒 × 1e8）：")
        if summary.apps.isEmpty {
            print("[history-demo]   （空：本机在这段时间没有产生可记录的应用活动）")
        }
        for (index, app) in summary.apps.prefix(5).enumerated() {
            print(String(format: "[history-demo]   %d. %-26@ ↓%@ ↑%@ cpu=%.3fs peakMem=%@ samples=%d",
                         index + 1, app.name as NSString,
                         formatBytes(Double(app.networkIn)), formatBytes(Double(app.networkOut)),
                         app.cpuSeconds, formatBytes(Double(app.peakMemoryBytes)), app.sampleCount))
        }

        // 单独把"按应用网络"列出来：Top 5 通常被 CPU 型应用占满，看不出网络那一路是否真的在工作。
        let byNetwork = summary.apps.filter { $0.networkTotal > 0 }
            .sorted { $0.networkTotal > $1.networkTotal }
        let appNetworkTotal = summary.apps.reduce(UInt64(0)) { $0 &+ $1.networkTotal }
        print("[history-demo] 应用网络合计 \(formatBytes(Double(appNetworkTotal)))"
              + "（\(byNetwork.count) 个应用有流量）：")
        for app in byNetwork.prefix(5) {
            print(String(format: "[history-demo]   %-26@ ↓%@ ↑%@", app.name as NSString,
                         formatBytes(Double(app.networkIn)), formatBytes(Double(app.networkOut))))
        }
        if byNetwork.isEmpty {
            print("[history-demo]   （这段时间里没有单个应用的网络增量 > 0）")
        }

        // ---- 开销实测 ----
        print(String(format: "[perf] HistoryStore.record(snapshot:) ×%d 平均 %.4fms 最大 %.4fms",
                     recordCount, recordCount > 0 ? recordTotal / Double(recordCount) : 0, recordMax))
        print(String(format: "[perf] HistoryStore.record(appSamples:) ×%d 平均 %.4fms 最大 %.4fms",
                     appRecordCount,
                     appRecordCount > 0 ? appRecordTotal / Double(appRecordCount) : 0, appRecordMax))
        print(String(format: "[perf] AppUsageCollector.sample() ×%d 平均 %.3fms 最大 %.3fms（含 %d 次 nettop）",
                     collectorSamples,
                     collectorSamples > 0 ? collectorTotal / Double(collectorSamples) : 0,
                     collectorMax, max(collectorSamples - 1, 0)))
        print("[perf] 单批应用样本最多 \(maxAppsInBatch) 条，其中 \(batchesWithNetwork) 批含网络增量")

        // ---- 落盘 + 存储信息 ----
        store.flush()
        print("")
        print("[history-demo] flush 后体积 \(store.storageBytes) 字节")
        listDirectory(store.storagePath)

        if options.historyReset {
            do {
                try store.resetAll()
                print("[history-demo] resetAll() 之后体积 \(store.storageBytes) 字节")
                listDirectory(store.storagePath)
            } catch {
                print("[history-demo] resetAll() 失败：\(error)")
                return 1
            }
        }
        return 0
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static func listDirectory(_ path: String) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: path) else {
            print("[history-demo]   （目录读取失败）")
            return
        }
        if entries.isEmpty {
            print("[history-demo]   （目录为空）")
            return
        }
        for name in entries.sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            let attributes = try? manager.attributesOfItem(atPath: full)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            print("[history-demo]   \(name)  \(size) 字节")
        }
    }
}
