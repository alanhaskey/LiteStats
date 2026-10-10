// 采样编排：把各传感器拼成一个 SystemSnapshot。
//
// 线程模型：单个 NSLock 保护全部增量状态；`sample()` 可在任意线程调用，
// 但内部是串行的（同一时刻只有一次系统调用序列在跑）。
// 不做定时器：调度完全交给应用层（调一次 = 采一拍）。
import Darwin
import Foundation

/// 线程安全。首次 `sample()`（或 `reset()` 之后）只建立基线，增量指标返回 0。
public final class SystemMonitor: @unchecked Sendable {
    /// 保护 `_configuration` 与所有传感器的增量状态。
    private let lock = NSLock()
    private var _configuration: MonitorConfiguration

    private let cpuSensor: CPUSensor
    private let memorySensor: MemorySensor
    private let gpuSensor: GPUSensor
    private let networkSensor: NetworkSensor
    private let diskSensor: DiskSensor

    /// 下一次 sample() 的序号（0 = 基线）。
    private var nextSampleIndex = 0
    /// 单调递增的采样计数，用于 GPU 隔拍刷新。
    private var tick = 0
    /// GPU 隔拍采样的缓存值。
    private var cachedGPU: GPUStats = .unavailable

    public init(configuration: MonitorConfiguration = .init()) {
        self._configuration = configuration
        self.cpuSensor = CPUSensor()
        self.memorySensor = MemorySensor()
        self.gpuSensor = GPUSensor()
        self.networkSensor = NetworkSensor()
        self.diskSensor = DiskSensor()
    }

    /// 采样配置。读写在锁内完成（`@unchecked Sendable` 下这是必要的）。
    public var configuration: MonitorConfiguration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    public var coreCount: Int { cpuSensor.coreCount }

    /// 采一拍。永不抛错、永不阻塞超过 ~10 ms；取不到的指标降级为 nil / 0。
    public func sample() -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }

        tick &+= 1
        let index = nextSampleIndex
        nextSampleIndex &+= 1

        let cpu = cpuSensor.sample()
        let memory = memorySensor.sample()
        let network = networkSensor.sample(now: Self.monotonicSeconds())

        // GPU：IOKit 读取代价最高（~0.9 ms），按配置隔 N 拍采一次，其余拍复用缓存。
        let gpuInterval = _configuration.normalizedGPUInterval
        let gpu: GPUStats
        if (tick - 1) % gpuInterval == 0 {
            gpu = gpuSensor.sample(tick: tick)
            cachedGPU = gpu
        } else {
            gpu = cachedGPU
        }

        let disk = _configuration.includeDisk ? diskSensor.sample() : nil

        let cpuStats = CPUStats(total: cpu.total, user: cpu.user, system: cpu.system,
                                idle: cpu.idle, perCore: cpu.perCore, coreCount: cpu.coreCount,
                                load1: cpu.load1, load5: cpu.load5, load15: cpu.load15)

        return SystemSnapshot(timestamp: Date(),
                              cpu: cpuStats,
                              memory: memory,
                              gpu: gpu,
                              network: network,
                              disk: disk,
                              uptime: ProcessInfo.processInfo.systemUptime,
                              thermalState: ProcessInfo.processInfo.thermalState,
                              sampleIndex: index)
    }

    /// 清空增量状态：下一次 `sample()` 重新返回基线（sampleIndex == 0，CPU/网络速率为 0）。
    /// 注意：GPU 句柄与磁盘容量不是增量状态，会被保留（避免重新枚举 IORegistry）。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        cpuSensor.reset()
        networkSensor.reset()
        nextSampleIndex = 0
        tick = 0
    }

    /// 单调时钟秒数（不受系统时间调整影响），用于网络速率的时间差。
    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
