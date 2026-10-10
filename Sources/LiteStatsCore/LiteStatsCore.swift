// ⚠️ 占位实现（由 core-agent 替换）
//
// 本文件只冻结 LiteStatsCore 的公开接口，内部实现是假的。
// 接口契约见 docs/architecture.md 的「LiteStatsCore 公开接口」一节，已冻结，不要改动签名。
// core-agent 需要把本文件删除，改为按功能拆分的真实实现（CPUMonitor/MemoryMonitor/...）。
import Foundation

// MARK: - 配置

public struct MonitorConfiguration: Sendable {
    /// 每 N 次采样读取一次 GPU（IOKit 读取代价最高，默认每 2 次读一次）。
    public var gpuRefreshEveryNTicks: Int
    /// 是否采样磁盘占用。
    public var includeDisk: Bool

    public init(gpuRefreshEveryNTicks: Int = 2, includeDisk: Bool = true) {
        self.gpuRefreshEveryNTicks = gpuRefreshEveryNTicks
        self.includeDisk = includeDisk
    }
}

// MARK: - 采样结果（全部为不可变值类型）

public struct CPUStats: Sendable, Equatable {
    /// 总体占用率 0...1
    public let total: Double
    /// 用户态占比 0...1（相对全部 tick）
    public let user: Double
    /// 系统态占比 0...1
    public let system: Double
    /// 空闲占比 0...1
    public let idle: Double
    /// 每个逻辑核心的占用率 0...1，count == coreCount
    public let perCore: [Double]
    public let coreCount: Int
    public let load1: Double
    public let load5: Double
    public let load15: Double

    public init(total: Double, user: Double, system: Double, idle: Double,
                perCore: [Double], coreCount: Int,
                load1: Double, load5: Double, load15: Double) {
        self.total = total
        self.user = user
        self.system = system
        self.idle = idle
        self.perCore = perCore
        self.coreCount = coreCount
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
    }
}

public struct MemoryStats: Sendable, Equatable {
    public let total: UInt64
    public let used: UInt64
    public let free: UInt64
    public let active: UInt64
    public let inactive: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    /// 可回收的文件缓存（internal - purgeable）
    public let cached: UInt64
    public let swapTotal: UInt64
    public let swapUsed: UInt64

    public var usage: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }

    public init(total: UInt64, used: UInt64, free: UInt64, active: UInt64, inactive: UInt64,
                wired: UInt64, compressed: UInt64, cached: UInt64,
                swapTotal: UInt64, swapUsed: UInt64) {
        self.total = total
        self.used = used
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
    }
}

public struct GPUStats: Sendable, Equatable {
    public let name: String?
    /// 0...1；取不到时为 nil（不要在 UI 里把 nil 当 0）
    public let utilization: Double?
    /// 已使用的显存（统一内存）字节数
    public let inUseMemory: UInt64?
    public let allocatedMemory: UInt64?

    public init(name: String?, utilization: Double?, inUseMemory: UInt64?, allocatedMemory: UInt64?) {
        self.name = name
        self.utilization = utilization
        self.inUseMemory = inUseMemory
        self.allocatedMemory = allocatedMemory
    }
}

public struct NetworkStats: Sendable, Equatable {
    /// 相对上一次采样的速率（字节/秒）
    public let download: Double
    public let upload: Double
    /// 自开机以来的累计字节数
    public let received: UInt64
    public let sent: UInt64
    public let interfaceName: String?
    public let isConnected: Bool

    public init(download: Double, upload: Double, received: UInt64, sent: UInt64,
                interfaceName: String?, isConnected: Bool) {
        self.download = download
        self.upload = upload
        self.received = received
        self.sent = sent
        self.interfaceName = interfaceName
        self.isConnected = isConnected
    }
}

public struct DiskStats: Sendable, Equatable {
    public let total: UInt64
    public let free: UInt64
    public let used: UInt64

    public var usage: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }

    public init(total: UInt64, free: UInt64, used: UInt64) {
        self.total = total
        self.free = free
        self.used = used
    }
}

public struct SystemSnapshot: Sendable {
    public let timestamp: Date
    public let cpu: CPUStats
    public let memory: MemoryStats
    public let gpu: GPUStats
    public let network: NetworkStats
    public let disk: DiskStats?
    public let uptime: TimeInterval
    public let thermalState: ProcessInfo.ThermalState
    /// 第几次采样；0 表示基线采样（此时 CPU/网络速率为 0）
    public let sampleIndex: Int

    public init(timestamp: Date, cpu: CPUStats, memory: MemoryStats, gpu: GPUStats,
                network: NetworkStats, disk: DiskStats?, uptime: TimeInterval,
                thermalState: ProcessInfo.ThermalState, sampleIndex: Int) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.network = network
        self.disk = disk
        self.uptime = uptime
        self.thermalState = thermalState
        self.sampleIndex = sampleIndex
    }
}

// MARK: - 纯函数（可单测，不碰硬件）

public enum CPUUsageMath {
    /// 从两次 `host_processor_info` 的 tick 数组计算占用率。
    /// `ticks` 布局与 CPU_STATE_MAX 一致：user, system, idle, nice，按核心连续排列。
    public static func compute(previous: [UInt32], current: [UInt32], coreCount: Int)
        -> (total: Double, user: Double, system: Double, idle: Double, perCore: [Double]) {
        // 占位：真实实现在 core-agent 的实现里
        (0, 0, 0, 1, Array(repeating: 0, count: max(coreCount, 0)))
    }
}

public enum NetworkRateMath {
    public static func bytesPerSecond(previous: UInt64, current: UInt64, interval: TimeInterval) -> Double {
        guard interval > 0, current >= previous else { return 0 }
        return Double(current - previous) / interval
    }
}

// MARK: - 采样器

/// 线程安全。首次 `sample()`（或 `reset()` 之后）只建立基线，增量指标返回 0。
public final class SystemMonitor: @unchecked Sendable {
    public init(configuration: MonitorConfiguration = .init()) {
        self.configuration = configuration
    }

    public var configuration: MonitorConfiguration

    public var coreCount: Int { ProcessInfo.processInfo.processorCount }

    public func sample() -> SystemSnapshot {
        // 占位：真实实现在 core-agent 的实现里
        let mem = MemoryStats(total: ProcessInfo.processInfo.physicalMemory, used: 0, free: 0,
                              active: 0, inactive: 0, wired: 0, compressed: 0, cached: 0,
                              swapTotal: 0, swapUsed: 0)
        return SystemSnapshot(
            timestamp: Date(),
            cpu: CPUStats(total: 0, user: 0, system: 0, idle: 1, perCore: [], coreCount: coreCount,
                          load1: 0, load5: 0, load15: 0),
            memory: mem,
            gpu: GPUStats(name: nil, utilization: nil, inUseMemory: nil, allocatedMemory: nil),
            network: NetworkStats(download: 0, upload: 0, received: 0, sent: 0,
                                  interfaceName: nil, isConnected: false),
            disk: nil,
            uptime: ProcessInfo.processInfo.systemUptime,
            thermalState: ProcessInfo.processInfo.thermalState,
            sampleIndex: 0
        )
    }

    public func reset() {}
}
