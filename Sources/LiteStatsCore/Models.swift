// LiteStatsCore 公开数据模型（接口已冻结，签名不得改动）。
//
// 本文件只放值类型；采样逻辑分散在 CPUSensor / MemorySensor / GPUSensor /
// NetworkSensor / DiskSensor，编排在 SystemMonitor。
// 约定：所有比率字段都是 0...1（不是百分比）；取不到的指标用 nil / 0，绝不抛错。
import Foundation

// MARK: - 配置

public struct MonitorConfiguration: Sendable {
    /// 每 N 次采样读取一次 GPU（IOKit 读取代价最高，默认每 2 次读一次）。
    /// <= 0 时按 1 处理（即每拍都读），避免取模/除零的边界问题。
    public var gpuRefreshEveryNTicks: Int
    /// 是否采样磁盘占用。
    public var includeDisk: Bool
    /// 是否采样温度 / 风扇（HID + AppleSMC）。关掉后 snapshot.thermal == .unavailable。
    public var includeThermal: Bool
    /// 每 N 次采样读取一次温度 / 风扇：温度变化慢（秒级），没必要每拍读。
    /// <= 0 时按 1 处理（即每拍都读）。
    public var thermalRefreshEveryNTicks: Int

    public init(gpuRefreshEveryNTicks: Int = 2, includeDisk: Bool = true,
                includeThermal: Bool = true, thermalRefreshEveryNTicks: Int = 5) {
        self.gpuRefreshEveryNTicks = gpuRefreshEveryNTicks
        self.includeDisk = includeDisk
        self.includeThermal = includeThermal
        self.thermalRefreshEveryNTicks = thermalRefreshEveryNTicks
    }

    /// 归一化后的 GPU 刷新间隔：永远 >= 1。
    var normalizedGPUInterval: Int { max(gpuRefreshEveryNTicks, 1) }

    /// 归一化后的温度刷新间隔：永远 >= 1。
    var normalizedThermalInterval: Int { max(thermalRefreshEveryNTicks, 1) }
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

    /// 基线（还没有两次 tick 可比较）时的取值：完全空闲。
    static func baseline(coreCount: Int, load1: Double, load5: Double, load15: Double) -> CPUStats {
        CPUStats(total: 0, user: 0, system: 0, idle: 1,
                 perCore: [Double](repeating: 0, count: max(coreCount, 0)),
                 coreCount: coreCount,
                 load1: load1, load5: load5, load15: load15)
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
    /// 可回收的文件缓存（file-backed 的 external 页减去 purgeable 页）
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

    /// 采样失败时的兜底值（全 0，usage 也就是 0，不会崩）。
    static let empty = MemoryStats(total: 0, used: 0, free: 0, active: 0, inactive: 0,
                                   wired: 0, compressed: 0, cached: 0, swapTotal: 0, swapUsed: 0)
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

    /// 完全取不到（无独显 / 权限受限 / 非 Apple GPU）时的降级值。
    public static let unavailable = GPUStats(name: nil, utilization: nil,
                                             inUseMemory: nil, allocatedMemory: nil)
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

    /// 接口全取不到时的降级值。
    public static let unavailable = NetworkStats(download: 0, upload: 0, received: 0, sent: 0,
                                                 interfaceName: nil, isConnected: false)
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
    /// 温度 / 风扇（HID + AppleSMC）。取不到时是 `.unavailable`（字段全 nil / 空数组）。
    public let thermal: ThermalStats

    public init(timestamp: Date, cpu: CPUStats, memory: MemoryStats, gpu: GPUStats,
                network: NetworkStats, disk: DiskStats?, uptime: TimeInterval,
                thermalState: ProcessInfo.ThermalState, sampleIndex: Int,
                thermal: ThermalStats = .unavailable) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.network = network
        self.disk = disk
        self.uptime = uptime
        self.thermalState = thermalState
        self.sampleIndex = sampleIndex
        self.thermal = thermal
    }
}

// MARK: - 温度 / 风扇（接口已冻结）

/// 温度传感器的分组，用于 UI 折叠与"代表温度"计算。
public enum ThermalGroup: String, Sendable, CaseIterable, Equatable {
    /// PMU tdie* / PMU tcal*（SoC 芯片上的温度点）
    case cpu
    /// 有 GPU 专属传感器时才归这里；本机（M5 Pro）没有，所以永远为空
    case gpu
    /// NAND CH* temp（SSD）
    case storage
    /// TB0T / Ts0P / gas gauge battery（电池）
    case battery
    case other

    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .storage: return "硬盘"
        case .battery: return "电池"
        case .other: return "其他"
        }
    }
}

public struct ThermalSensor: Sendable, Equatable, Identifiable {
    public let name: String        // "PMU tdie4"
    public let celsius: Double     // 已过滤掉离谱值
    public let group: ThermalGroup
    public var id: String { name }
    public init(name: String, celsius: Double, group: ThermalGroup) {
        self.name = name
        self.celsius = celsius
        self.group = group
    }
}

public struct FanReading: Sendable, Equatable {
    public let index: Int          // 0,1,...
    public let rpm: Double?        // 当前转速（F{i}Ac）
    public let minRPM: Double?     // F{i}Mn
    public let maxRPM: Double?     // F{i}Mx
    public let targetRPM: Double?  // F{i}Tg
    public init(index: Int, rpm: Double?, minRPM: Double?, maxRPM: Double?, targetRPM: Double?) {
        self.index = index
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
    }
}

public struct ThermalStats: Sendable, Equatable {
    /// CPU 代表温度：取所有有效 cpu 组传感器的最大值；无有效值时为 nil
    public let cpuTemperature: Double?
    /// GPU 温度：本机无 GPU 专属传感器时应为 nil（不要拿 CPU 温度冒充）
    public let gpuTemperature: Double?
    public let batteryTemperature: Double?
    /// 全部有效传感器（已过滤垃圾值），按 name 排序，便于设置界面让用户挑
    public let sensors: [ThermalSensor]
    public let fans: [FanReading]
    /// 数据来源描述，例如 "HID(76 个传感器) + SMC(2 个风扇)"；都失败时 nil
    public let sourceDescription: String?
    /// 本次读取耗时（毫秒）
    public let readMillis: Double

    public init(cpuTemperature: Double?, gpuTemperature: Double?, batteryTemperature: Double?,
                sensors: [ThermalSensor], fans: [FanReading],
                sourceDescription: String?, readMillis: Double) {
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.batteryTemperature = batteryTemperature
        self.sensors = sensors
        self.fans = fans
        self.sourceDescription = sourceDescription
        self.readMillis = readMillis
    }

    /// 完全取不到（HID 与 SMC 都没有可用数据）时的降级值。
    /// 注意：readMillis 也是 0 —— 完全失败时连耗时都不上报，避免 UI 显示"读了 2ms 但没数据"。
    public static let unavailable = ThermalStats(cpuTemperature: nil, gpuTemperature: nil,
                                                 batteryTemperature: nil,
                                                 sensors: [], fans: [],
                                                 sourceDescription: nil, readMillis: 0)
}
