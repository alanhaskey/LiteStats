// 纯函数：CPU tick 差分与网络速率换算。这些函数不碰硬件，单测重点覆盖（含边界）。
import Foundation

/// 每个核心在 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` 里占 4 个 tick：
/// 顺序永远是 user, system, idle, nice（即 CPU_STATE_USER/SYSTEM/IDLE/NICE）。
let ticksPerCore = 4

/// 0...1 夹取；NaN 归 0（避免把 NaN 泄漏到 UI）。
@inline(__always)
func clamp01(_ value: Double) -> Double {
    if value.isNaN { return 0 }
    return min(max(value, 0), 1)
}

/// 两个 32 位 tick 的差值，**按 2^32 回绕**处理。
///
/// 坑：`processor_cpu_load_info` 的 tick 是 `natural_t`（32 位），单核满负载约
/// 100 tick/s，理论上 497 天回绕一次；但 `natural_t` 本身也可能被系统重置。
/// 用 `&-`（mod 2^32）做差，回绕时得到的是"真实增量"，而不会变成一个天文数字。
@inline(__always)
func tickDelta(_ previous: UInt32, _ current: UInt32) -> UInt64 {
    UInt64(current &- previous)
}

public enum CPUUsageMath {
    /// 从两次 `host_processor_info` 的 tick 数组计算占用率。
    /// `ticks` 布局与 CPU_STATE_MAX 一致：user, system, idle, nice，按核心连续排列。
    ///
    /// 约定：
    /// - `nice` 并入 `user`（UI 只展示 user/system/idle 三段）。
    /// - `total = user + system = 1 - idle`，四个值都被夹在 0...1。
    /// - 数组长度不足 `coreCount * 4` 时，缺失的核心按 0 处理，但 `perCore.count`
    ///   永远等于 `max(coreCount, 0)`（UI 可以按下标一一对应）。
    /// - 增量和为 0（两拍之间没有任何 tick 流逝）时不做除法，返回
    ///   `total=0, user=0, system=0, idle=1`（即"测不到变化 = 无负载"）。
    public static func compute(previous: [UInt32], current: [UInt32], coreCount: Int)
        -> (total: Double, user: Double, system: Double, idle: Double, perCore: [Double]) {
        let cores = max(coreCount, 0)
        guard cores > 0 else { return (0, 0, 0, 1, []) }

        var perCore = [Double](repeating: 0, count: cores)
        // 只处理两拍都齐全的核心；短数组不会越界。
        let usable = min(cores, min(previous.count, current.count) / ticksPerCore)

        var userTicks: UInt64 = 0
        var systemTicks: UInt64 = 0
        var idleTicks: UInt64 = 0

        for core in 0..<usable {
            let base = core * ticksPerCore
            let dUser = tickDelta(previous[base], current[base])
            let dSystem = tickDelta(previous[base + 1], current[base + 1])
            let dIdle = tickDelta(previous[base + 2], current[base + 2])
            let dNice = tickDelta(previous[base + 3], current[base + 3])

            let busy = dUser + dNice + dSystem
            let sum = busy + dIdle
            // 单核增量为 0：保持 0，避免 0/0。
            if sum > 0 { perCore[core] = clamp01(Double(busy) / Double(sum)) }

            userTicks += dUser + dNice
            systemTicks += dSystem
            idleTicks += dIdle
        }

        let all = userTicks + systemTicks + idleTicks
        guard all > 0 else { return (0, 0, 0, 1, perCore) }

        let idle = clamp01(Double(idleTicks) / Double(all))
        let user = clamp01(Double(userTicks) / Double(all))
        let system = clamp01(Double(systemTicks) / Double(all))
        // 用 1 - idle 而不是 user + system，保证三者相加恰为 1（浮点舍入下更稳）。
        let total = clamp01(1 - idle)
        return (total, user, system, idle, perCore)
    }
}

public enum NetworkRateMath {
    /// 速率换算。`current < previous` 说明计数器被重置（接口重连 / 32 位回绕），
    /// 此时返回 0 而不是负数或巨大值；`interval <= 0` 同样返回 0。
    public static func bytesPerSecond(previous: UInt64, current: UInt64, interval: TimeInterval) -> Double {
        guard interval > 0, current >= previous else { return 0 }
        return Double(current - previous) / interval
    }
}
