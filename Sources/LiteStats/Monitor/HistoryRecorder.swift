import Foundation
import LiteStatsCore

/// 历史记录的采集调度。
///
/// 两路数据：
/// 1. 系统快照：复用 `MonitorService` 每拍的回调（主线程），`HistoryStore.record` 内部只做内存聚合，目标 <1ms；
/// 2. 按应用：独立的后台定时器（默认 5s），跑 `AppUsageCollector`（libproc 遍历 + 每 6 次跑一次 nettop）。
///
/// 开销实测：libproc 遍历 196 个进程 ≈0.5ms，nettop 单次 ≈10ms（每 6 次采样跑一次）
/// → 折算 ≈0.04% CPU，可以忽略。
@MainActor
final class HistoryRecorder {
    private let store: HistoryStore
    private let collector: AppUsageCollector
    private let queue = DispatchQueue(label: "com.litestats.history", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var started = false

    /// 应用采样间隔（秒）
    var appInterval: TimeInterval = 5

    init(store: HistoryStore, collector: AppUsageCollector = AppUsageCollector()) {
        self.store = store
        self.collector = collector
    }

    func start() {
        guard !started else { return }
        started = true
        restartTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        started = false
        store.flush()
    }

    /// 每拍系统快照（主线程调用，必须很快）
    func record(snapshot: SystemSnapshot, interval: TimeInterval) {
        store.record(snapshot: snapshot, interval: interval)
    }

    private func restartTimer() {
        timer?.cancel()
        let collector = self.collector
        let store = self.store
        let interval = max(2, appInterval)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { @Sendable in
            let samples = collector.sample()
            guard !samples.isEmpty else { return }
            store.record(appSamples: samples, interval: interval)
        }
        t.resume()
        timer = t
    }
}
