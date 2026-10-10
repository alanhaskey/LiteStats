// LiteStatsCore 历史统计的公开数据模型。
//
// 约定与 Models.swift 一致：
//   * 全部是 Sendable 值类型，没有引用语义；
//   * 比率字段是 0...1（不是百分比）；
//   * 取不到的指标用 nil / 0，构造器不抛错、不产生 NaN。
//
// ⚠️ 这些签名已经冻结（UI 层直接消费），只允许"追加"新成员，不要改已有字段名/顺序。
import Foundation

// MARK: - 分钟级明细

/// 一分钟的聚合结果。`cpuSeconds` 是这一分钟内**所有核心合计**消耗的 CPU 秒数，
/// 所以 8 核满载一分钟是 60 × 8 = 480（不是 60）。
public struct MinuteSample: Sendable, Equatable {
    /// 该分钟的时间起点（本地日历的整分钟，不是"第一条样本的时间"）
    public let date: Date
    /// 这一分钟内累计的 CPU 秒数（多核可 > 60）
    public let cpuSeconds: Double
    /// GPU 利用率的时间加权平均，0...1；无数据用 0
    public let gpuPercentAverage: Double
    /// 内存占用的时间加权平均（字节）
    public let memoryBytesAverage: Double
    /// 这一分钟内的增量字节
    public let networkIn: UInt64
    public let networkOut: UInt64
    /// 这一分钟内出现过的最高 CPU 温度（摄氏度）；整分钟都没有温度数据时为 nil
    public let temperatureMax: Double?

    public init(date: Date, cpuSeconds: Double, gpuPercentAverage: Double,
                memoryBytesAverage: Double, networkIn: UInt64, networkOut: UInt64,
                temperatureMax: Double?) {
        self.date = date
        self.cpuSeconds = cpuSeconds
        self.gpuPercentAverage = gpuPercentAverage
        self.memoryBytesAverage = memoryBytesAverage
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.temperatureMax = temperatureMax
    }
}

// MARK: - 小时级汇总

/// 一小时的分桶。由分钟级明细滚动合成（分钟级只留 7 天，小时级留 180 天）。
public struct HourlyBucket: Sendable, Equatable, Identifiable {
    public let hourStart: Date
    public let cpuSeconds: Double
    public let gpuPercentAverage: Double
    public let memoryBytesAverage: Double
    public let networkIn: UInt64
    public let networkOut: UInt64
    /// 该小时里实际记录到的采样拍数（由分钟明细合成时 = 参与合成的分钟数）
    public let sampleCount: Int

    public var id: Date { hourStart }

    /// 这一小时的平均 CPU 占用（0...1，相对"整机全部核心满载一小时"）。
    /// 用固定 3600 秒做分母（契约如此），跨夏令时的那一小时会有轻微偏差。
    public var cpuPercentOfHour: Double {
        guard cpuSeconds > 0 else { return 0 }
        return min(cpuSeconds / 3600.0, 1.0)
    }

    public init(hourStart: Date, cpuSeconds: Double, gpuPercentAverage: Double,
                memoryBytesAverage: Double, networkIn: UInt64, networkOut: UInt64,
                sampleCount: Int) {
        self.hourStart = hourStart
        self.cpuSeconds = cpuSeconds
        self.gpuPercentAverage = gpuPercentAverage
        self.memoryBytesAverage = memoryBytesAverage
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.sampleCount = sampleCount
    }

    public var networkTotal: UInt64 { networkIn &+ networkOut }
}

// MARK: - 按应用

/// 单个应用在一个区间内的累计占用。身份是**进程名**（`proc_name`），不是 bundle id：
/// helper / 子进程会合并到同一个名字下（例如多个 "Google Chrome Helper"）。
public struct AppUsage: Sendable, Equatable, Identifiable {
    public let name: String
    /// 可执行文件路径，可能为 nil（进程已退出 / 无权限查 path）
    public let path: String?
    public let cpuSeconds: Double
    /// 该区间内观测到的常驻内存峰值（同名的多个进程会相加）
    public let peakMemoryBytes: UInt64
    public let networkIn: UInt64
    public let networkOut: UInt64
    /// 观测到该应用的采样次数
    public let sampleCount: Int

    public var id: String { name }

    public var networkTotal: UInt64 { networkIn &+ networkOut }

    public init(name: String, path: String?, cpuSeconds: Double, peakMemoryBytes: UInt64,
                networkIn: UInt64, networkOut: UInt64, sampleCount: Int) {
        self.name = name
        self.path = path
        self.cpuSeconds = cpuSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.sampleCount = sampleCount
    }
}

// MARK: - 区间汇总

/// 任意区间的汇总结果（今天 / 昨天 / 本周 / 本月 / 自定义区间都走这里）。
public struct UsageSummary: Sendable, Equatable {
    public let rangeStart: Date
    public let rangeEnd: Date
    public let networkIn: UInt64
    public let networkOut: UInt64
    public let cpuSeconds: Double
    /// `gpuPercentAverage` 对时间的积分（0.5 的利用率跑 10 秒 = 5）
    public let gpuSeconds: Double
    public let memoryBytesAverage: Double
    /// 区间内按小时，已按时间升序；**只包含真正有数据的小时**（没有采样的小时不补 0 桶）
    public let hourly: [HourlyBucket]
    /// 已按"影响"降序（见 HistoryRanking.impactWeight 的公式）
    public let apps: [AppUsage]
    /// 实际记录到的总时长（秒），用于算平均值。应用没运行的时间不算在内。
    public let trackDuration: TimeInterval

    public init(rangeStart: Date, rangeEnd: Date, networkIn: UInt64, networkOut: UInt64,
                cpuSeconds: Double, gpuSeconds: Double, memoryBytesAverage: Double,
                hourly: [HourlyBucket], apps: [AppUsage], trackDuration: TimeInterval) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.networkIn = networkIn
        self.networkOut = networkOut
        self.cpuSeconds = cpuSeconds
        self.gpuSeconds = gpuSeconds
        self.memoryBytesAverage = memoryBytesAverage
        self.hourly = hourly
        self.apps = apps
        self.trackDuration = trackDuration
    }

    public var networkTotal: UInt64 { networkIn &+ networkOut }

    /// 平均 CPU 占用（0...个数核心）——用 cpuSeconds / (trackDuration * coreCount)。
    /// coreCount 传 0 或没有记录时长时返回 0（不产生 NaN / inf）。
    public func averageCPUUsage(coreCount: Int) -> Double {
        guard coreCount > 0, trackDuration > 0, cpuSeconds > 0 else { return 0 }
        return cpuSeconds / (trackDuration * Double(coreCount))
    }

    /// 平均 GPU 占用（0...1）。
    public var averageGPUUsage: Double {
        guard trackDuration > 0, gpuSeconds > 0 else { return 0 }
        return min(gpuSeconds / trackDuration, 1)
    }

    /// 空汇总（无数据 / 非法区间时的返回值）。
    public static func empty(from: Date, to: Date) -> UsageSummary {
        UsageSummary(rangeStart: from, rangeEnd: to, networkIn: 0, networkOut: 0,
                     cpuSeconds: 0, gpuSeconds: 0, memoryBytesAverage: 0,
                     hourly: [], apps: [], trackDuration: 0)
    }
}

// MARK: - 按应用的增量样本

/// `AppUsageCollector` 每次采样返回一条：字段是**自上次采样以来的增量**
/// （`memoryBytes` 例外，它是当前值）。
public struct AppUsageSample: Sendable, Equatable {
    public let name: String
    public let path: String?
    /// 自上次采样以来的 CPU 增量（秒，user + system，多核可叠加）
    public let cpuSeconds: Double
    /// 当前常驻内存（字节，不是增量）；同名进程已相加
    public let memoryBytes: UInt64
    /// 自上次采样以来的网络增量
    public let networkIn: UInt64
    public let networkOut: UInt64

    public init(name: String, path: String?, cpuSeconds: Double, memoryBytes: UInt64,
                networkIn: UInt64, networkOut: UInt64) {
        self.name = name
        self.path = path
        self.cpuSeconds = cpuSeconds
        self.memoryBytes = memoryBytes
        self.networkIn = networkIn
        self.networkOut = networkOut
    }
}

// MARK: - 排序权重

/// `UsageSummary.apps` 的排序公式，单独抽出来便于 UI 复用与单测。
public enum HistoryRanking {
    /// 1 秒 CPU 折算成多少字节的"等效流量"。
    /// 取 1e8（= 100MB）是量级感：持续占 1 个核跑 1 秒 ≈ 下载 100MB 的"影响程度"。
    public static let bytesPerCPUSecond: Double = 1e8

    /// 综合影响权重 = 网络总字节 + CPU 秒 × 1e8。
    /// 用 Double 累加：网络字节可能是上百 GB，整数相加有溢出风险；
    /// 而排序只需要相对大小，Double 的 53 位有效位足够。
    public static func impactWeight(networkIn: UInt64, networkOut: UInt64, cpuSeconds: Double) -> Double {
        let net = Double(networkIn) + Double(networkOut)
        return net + max(0, cpuSeconds) * bytesPerCPUSecond
    }

    public static func impactWeight(_ usage: AppUsage) -> Double {
        impactWeight(networkIn: usage.networkIn, networkOut: usage.networkOut,
                     cpuSeconds: usage.cpuSeconds)
    }
}
