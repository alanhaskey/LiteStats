// usage 计算属性与配置的边界单测：total == 0 不能崩、边界 0 与 1。
import Testing
@testable import LiteStatsCore

@Suite("usage 与配置边界")
struct UsageMathTests {
    @Test func memoryUsageBasics() {
        let empty = MemoryStats.empty
        #expect(empty.usage == 0)          // total == 0 → 0，不产生 NaN

        let zero = MemoryStats(total: 0, used: 0, free: 0, active: 0, inactive: 0, wired: 0,
                               compressed: 0, cached: 0, swapTotal: 0, swapUsed: 0)
        #expect(zero.usage == 0)

        // total == 0 但 used 非 0（异常情况）也不能除零
        let inconsistent = MemoryStats(total: 0, used: 12345, free: 0, active: 0, inactive: 0,
                                       wired: 0, compressed: 0, cached: 0, swapTotal: 0, swapUsed: 0)
        #expect(inconsistent.usage == 0)
        #expect(!inconsistent.usage.isNaN)
    }

    @Test func memoryUsageBoundaries() {
        func make(total: UInt64, used: UInt64) -> MemoryStats {
            MemoryStats(total: total, used: used, free: total - used, active: used, inactive: 0,
                        wired: 0, compressed: 0, cached: 0, swapTotal: 0, swapUsed: 0)
        }
        #expect(make(total: 100, used: 0).usage == 0)
        #expect(make(total: 100, used: 100).usage == 1)
        #expect(abs(make(total: 24_000_000_000, used: 18_000_000_000).usage - 0.75) < 1e-12)
        #expect(make(total: UInt64.max, used: UInt64.max).usage == 1)
    }

    @Test func diskUsageBoundaries() {
        #expect(DiskStats(total: 0, free: 0, used: 0).usage == 0)
        #expect(DiskStats(total: 0, free: 0, used: 999).usage == 0)   // 不除零
        #expect(DiskStats(total: 100, free: 100, used: 0).usage == 0)
        #expect(DiskStats(total: 100, free: 0, used: 100).usage == 1)
        #expect(DiskStats(total: 994_610_155_520, free: 400_000_000_000,
                          used: 594_610_155_520).usage > 0.59)
    }

    @Test func gpuUnavailableStaysNil() {
        // nil 不能被当作 0（UI 依赖这一点）
        #expect(GPUStats.unavailable.utilization == nil)
        #expect(GPUStats.unavailable.name == nil)
        #expect(GPUStats.unavailable.inUseMemory == nil)
        #expect(GPUStats.unavailable.allocatedMemory == nil)
    }

    @Test func networkUnavailableIsZeroed() {
        let stats = NetworkStats.unavailable
        #expect(stats.download == 0 && stats.upload == 0)
        #expect(stats.received == 0 && stats.sent == 0)
        #expect(stats.interfaceName == nil)
        #expect(stats.isConnected == false)
    }

    @Test func configurationDefaults() {
        let config = MonitorConfiguration()
        #expect(config.gpuRefreshEveryNTicks == 2)
        #expect(config.includeDisk == true)
        #expect(config.normalizedGPUInterval == 2)
        // 0 / 负数按 1 处理，避免取模异常
        #expect(MonitorConfiguration(gpuRefreshEveryNTicks: 0).normalizedGPUInterval == 1)
        #expect(MonitorConfiguration(gpuRefreshEveryNTicks: -5).normalizedGPUInterval == 1)
        #expect(MonitorConfiguration(gpuRefreshEveryNTicks: 7).normalizedGPUInterval == 7)
    }

    @Test func valueTypesAreEquatable() {
        let a = CPUStats(total: 0.5, user: 0.3, system: 0.2, idle: 0.5, perCore: [0.5],
                         coreCount: 1, load1: 1, load5: 2, load15: 3)
        let b = CPUStats(total: 0.5, user: 0.3, system: 0.2, idle: 0.5, perCore: [0.5],
                         coreCount: 1, load1: 1, load5: 2, load15: 3)
        #expect(a == b)

        let g1 = GPUStats(name: "Apple M5 Pro", utilization: 0.5, inUseMemory: 1, allocatedMemory: 2)
        let g2 = GPUStats(name: "Apple M5 Pro", utilization: 0.5, inUseMemory: 1, allocatedMemory: 2)
        #expect(g1 == g2)
        #expect(g1 != GPUStats.unavailable)

        #expect(DiskStats(total: 10, free: 5, used: 5) == DiskStats(total: 10, free: 5, used: 5))
        #expect(NetworkStats.unavailable == NetworkStats(download: 0, upload: 0, received: 0,
                                                         sent: 0, interfaceName: nil,
                                                         isConnected: false))
    }

    @Test func baselineCPUStats() {
        let baseline = CPUStats.baseline(coreCount: 3, load1: 1, load5: 2, load15: 3)
        #expect(baseline.total == 0)
        #expect(baseline.idle == 1)
        #expect(baseline.perCore.count == 3)
        #expect(baseline.perCore.allSatisfy { $0 == 0 })
    }
}
