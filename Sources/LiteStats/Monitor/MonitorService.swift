import AppKit
import Foundation
import LiteStatsCore

/// 定长环形缓冲，用于迷你折线图（避免 `removeFirst` 之外的任何分配）。
struct RingBuffer {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        values.reserveCapacity(self.capacity)
    }

    mutating func append(_ value: Double) {
        if values.count == capacity {
            values.removeFirst()
        }
        values.append(value)
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
    }
}

/// 采样调度与历史缓存。UI 只读这里的数据。
///
/// 开销控制：
/// - 单个 `DispatchSourceTimer`，跑在 utility 队列上；采样本身是"被调用一次算一次"，不含定时器；
/// - 收起态降频（默认 2 s），展开态升频（默认 1 s），悬浮瞬间立刻补一拍；
/// - 系统/屏幕休眠时完全停止采样。
@MainActor
@Observable
final class MonitorService {
    private(set) var snapshot: SystemSnapshot?
    private(set) var sampleCount = 0
    private(set) var lastSampleMillis: Double = 0

    private(set) var cpuHistory = RingBuffer(capacity: 60)
    private(set) var memoryHistory = RingBuffer(capacity: 60)
    private(set) var gpuHistory = RingBuffer(capacity: 60)
    private(set) var downHistory = RingBuffer(capacity: 60)
    private(set) var upHistory = RingBuffer(capacity: 60)

    /// 面板是否展开：决定采样频率
    var isPanelExpanded = false {
        didSet {
            guard oldValue != isPanelExpanded else { return }
            if isPanelExpanded { sampleNow() }
            restartTimer()
        }
    }

    private let monitor: SystemMonitor
    private let queue = DispatchQueue(label: "com.litestats.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var started = false

    /// 采样间隔：收起态可以慢一点（省电），展开态快一点（跟手）
    var intervalExpanded: TimeInterval = 1.0
    var intervalCollapsed: TimeInterval = 2.0

    init(configuration: MonitorConfiguration = .init()) {
        self.monitor = SystemMonitor(configuration: configuration)
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    var coreCount: Int { monitor.coreCount }
    var interval: TimeInterval { isPanelExpanded ? intervalExpanded : intervalCollapsed }

    func setIntervals(expanded: TimeInterval, collapsed: TimeInterval) {
        intervalExpanded = max(0.2, expanded)
        intervalCollapsed = max(0.2, collapsed)
        restartTimer()
    }

    func start() {
        guard !started else { return }
        started = true
        // 先同步跑一拍建立基线，避免首次展开时增量指标全是 0
        sampleNow()
        restartTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        started = false
    }

    private func restartTimer() {
        guard started else { return }
        timer?.cancel()
        // 注意 1：必须在闭包外取出 monitor（SystemMonitor 是 Sendable 的值持有者）。
        // 注意 2：闭包必须显式标 `@Sendable`。`setEventHandler` 的参数类型没有 @Sendable，
        //         于是这个闭包会**继承**外层的 @MainActor 隔离，被 DispatchSource 在后台队列
        //         调用时 Swift 运行时会判定"@MainActor 函数不在主线程执行"并反复报 data race。
        let monitor = self.monitor
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(120))
        t.setEventHandler { @Sendable [weak self] in
            let t0 = DispatchTime.now()
            let snap = monitor.sample()
            let millis = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            Task { @MainActor in self?.ingest(snap, sampleMillis: millis) }
        }
        t.resume()
        timer = t
    }

    /// 立刻补一拍（悬浮展开时调用，保证数据是新的）
    func sampleNow() {
        let monitor = self.monitor
        queue.async { [weak self] in
            let t0 = DispatchTime.now()
            let snap = monitor.sample()
            let millis = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            Task { @MainActor in self?.ingest(snap, sampleMillis: millis) }
        }
    }

    private func ingest(_ snap: SystemSnapshot, sampleMillis: Double) {
        snapshot = snap
        sampleCount += 1
        lastSampleMillis = sampleMillis
        cpuHistory.append(snap.cpu.total)
        memoryHistory.append(snap.memory.usage)
        gpuHistory.append(snap.gpu.utilization ?? 0)
        downHistory.append(snap.network.download)
        upHistory.append(snap.network.upload)
    }

    @objc private func systemWillSleep() {
        // 通知在主线程投递
        MainActor.assumeIsolated { stop() }
    }

    @objc private func systemDidWake() {
        MainActor.assumeIsolated {
            started = true
            sampleNow()
            restartTimer()
        }
    }
}
