// 采样器契约冒烟测试：基线语义（首次 sample / reset 后 sampleIndex == 0、增量为 0）
// 与线程安全。这里会真的调用系统调用（sysctl / mach），属于集成冒烟，不做数值断言。
import Foundation
import Testing
@testable import LiteStatsCore

@Suite("SystemMonitor 契约")
struct SystemMonitorTests {
    @Test func coreCountMatchesProcessInfo() {
        let monitor = SystemMonitor()
        #expect(monitor.coreCount == ProcessInfo.processInfo.processorCount)
        #expect(monitor.coreCount > 0)
    }

    @Test func firstSampleIsBaseline() {
        let monitor = SystemMonitor()
        let first = monitor.sample()
        #expect(first.sampleIndex == 0)
        #expect(first.cpu.total == 0)          // 基线的 CPU 增量必须为 0
        #expect(first.network.download == 0)
        #expect(first.network.upload == 0)
        #expect(first.cpu.perCore.count == first.cpu.coreCount)  // 长度不变量
        #expect(first.uptime > 0)
        #expect(first.timestamp.timeIntervalSinceNow > -5)

        let second = monitor.sample()
        #expect(second.sampleIndex == 1)
        #expect(second.cpu.total >= 0 && second.cpu.total <= 1)
        #expect(second.cpu.perCore.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(second.network.download >= 0)
        #expect(second.network.upload >= 0)
    }

    @Test func resetRestoresBaseline() {
        let monitor = SystemMonitor()
        _ = monitor.sample()
        _ = monitor.sample()
        monitor.reset()
        let afterReset = monitor.sample()
        #expect(afterReset.sampleIndex == 0)
        #expect(afterReset.cpu.total == 0)
        #expect(afterReset.network.download == 0)
        #expect(afterReset.network.upload == 0)
    }

    @Test func configurationIsReadableAndWritable() {
        let monitor = SystemMonitor(configuration: MonitorConfiguration(gpuRefreshEveryNTicks: 3,
                                                                       includeDisk: false))
        #expect(monitor.configuration.gpuRefreshEveryNTicks == 3)
        #expect(monitor.configuration.includeDisk == false)
        // includeDisk = false 时 disk 必须是 nil
        #expect(monitor.sample().disk == nil)

        monitor.configuration = MonitorConfiguration(gpuRefreshEveryNTicks: 1, includeDisk: true)
        #expect(monitor.configuration.includeDisk == true)
        #expect(monitor.configuration.gpuRefreshEveryNTicks == 1)
    }

    @Test func memoryTotalMatchesPhysicalMemory() {
        let snapshot = SystemMonitor().sample()
        #expect(snapshot.memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.memory.usage >= 0 && snapshot.memory.usage <= 1)
    }

    /// sample() 必须可以在任意线程并发调用，且内部状态被锁串行化
    /// （40 次调用拿到的 sampleIndex 必须是 0..<40 的一个排列）。
    @Test func concurrentSamplingIsSerialised() {
        let monitor = SystemMonitor()
        let box = IndexBox()

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<5 {
                let snapshot = monitor.sample()
                box.append(snapshot.sampleIndex)
            }
        }

        let indexes = box.snapshot()
        #expect(indexes.count == 40)
        #expect(Set(indexes) == Set(0..<40))
    }

    /// 并发读配置不会崩（配置读写在锁内）。
    @Test func concurrentConfigurationAccess() {
        let monitor = SystemMonitor()
        DispatchQueue.concurrentPerform(iterations: 8) { iteration in
            for _ in 0..<50 {
                if iteration % 2 == 0 {
                    monitor.configuration = MonitorConfiguration(gpuRefreshEveryNTicks: 2,
                                                                 includeDisk: true)
                } else {
                    _ = monitor.configuration.gpuRefreshEveryNTicks
                }
            }
        }
        #expect(monitor.configuration.gpuRefreshEveryNTicks == 2)
    }
}

/// 并发收集数组用的线程安全盒子（避免捕获可变 var 触发 Swift 6 并发检查）。
private final class IndexBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.withLock { values.append(value) }
    }

    func snapshot() -> [Int] {
        lock.withLock { values }
    }
}
