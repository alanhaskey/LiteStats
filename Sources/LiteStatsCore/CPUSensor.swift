// CPU 传感器：host_processor_info(PROCESSOR_CPU_LOAD_INFO) + getloadavg。
import Darwin
import Foundation

/// 一次 CPU 采样结果（内部类型，不对外暴露）。
struct CPUReading {
    var coreCount: Int
    var total: Double
    var user: Double
    var system: Double
    var idle: Double
    var perCore: [Double]
    var load1: Double
    var load5: Double
    var load15: Double
}

final class CPUSensor {
    /// 逻辑核心数（来自 ProcessInfo，进程生命周期内不变，用于分配缓冲区）。
    let coreCount: Int

    /// 缓存 host port：`mach_host_self()` 每次调用都会 +1 send right，
    /// 每拍都调会累积端口引用，所以只取一次、deinit 时归还。
    private let host: host_t

    /// 上一拍 / 这一拍的 tick 缓冲，复用避免每拍堆分配。
    /// 布局：每核心 4 个 UInt32（user, system, idle, nice）。
    private var previousTicks: [UInt32] = []
    private var currentTicks: [UInt32] = []

    /// 最近一次成功读取的结果；底层调用失败时返回它（宁可给旧值也不要 0 抖动）。
    private var lastGood: CPUReading?

    init() {
        coreCount = max(ProcessInfo.processInfo.processorCount, 1)
        host = mach_host_self()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// 采一拍。永不抛错：失败时返回上一次的良好值；从未成功过则返回 coreCount = 0
    /// 的基线（`perCore` 为空数组，与 coreCount 保持一致，上层可据此判定传感器不可用）。
    func sample() -> CPUReading {
        let (load1, load5, load15) = Self.loadAverages()

        guard let ticks = readTicks() else {
            if let lastGood { return lastGood }
            return CPUReading(coreCount: 0, total: 0, user: 0, system: 0, idle: 1, perCore: [],
                              load1: load1, load5: load5, load15: load15)
        }

        // tick 数 / 4 = 本次实际读到的核心数
        let usableCores = max(min(ticks.count / ticksPerCore, coreCount), 0)

        // previous <- current（第一拍 previous 为空 → 基线）
        swap(&previousTicks, &currentTicks)
        currentTicks.removeAll(keepingCapacity: true)
        currentTicks.append(contentsOf: ticks)

        let reading: CPUReading
        if previousTicks.isEmpty {
            // 首次采样（或 reset 之后）：只建立基线，增量为 0。
            reading = CPUReading(coreCount: usableCores, total: 0, user: 0, system: 0, idle: 1,
                                 perCore: [Double](repeating: 0, count: usableCores),
                                 load1: load1, load5: load5, load15: load15)
        } else {
            let c = CPUUsageMath.compute(previous: previousTicks, current: currentTicks,
                                         coreCount: usableCores)
            reading = CPUReading(coreCount: usableCores, total: c.total, user: c.user,
                                 system: c.system, idle: c.idle, perCore: c.perCore,
                                 load1: load1, load5: load5, load15: load15)
        }
        lastGood = reading
        return reading
    }

    /// 清空增量状态：下一次 sample() 重新建立基线。
    /// （`lastGood` 只是失败兜底、不是增量状态，所以保留。）
    func reset() {
        previousTicks.removeAll(keepingCapacity: true)
        currentTicks.removeAll(keepingCapacity: true)
    }

    // MARK: - 底层调用

    /// 读取 tick 数组。
    ///
    /// 坑 1：`processor_info_array_t` 是内核在**调用者任务**里分配的 vm 内存，
    ///       必须 `vm_deallocate`，否则每次采样泄漏（1 Hz 跑一天约 20 MB）。
    /// 坑 2：`infoCount` 是 `integer_t` 的个数（= 核心数 * CPU_STATE_MAX = 60），
    ///       而 `processorCount` 是核心数（15），两者别混。
    /// 坑 3：tick 是 32 位（`natural_t`），差分必须按 2^32 回绕处理（见 CPUUsageMath）。
    private func readTicks() -> [UInt32]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO,
                                         &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info, processorCount > 0, infoCount > 0 else {
            return nil
        }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        // tick 是无符号计数，但内核按 integer_t(Int32) 传出，这里按位重新解释为 UInt32。
        let count = Int(infoCount)
        let buffer = UnsafeRawPointer(info).assumingMemoryBound(to: UInt32.self)
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    /// `getloadavg` 取不到时返回全 0（不抛错）。
    private static func loadAverages() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        let n = getloadavg(&loads, 3)
        guard n > 0 else { return (0, 0, 0) }
        return (loads[0], n > 1 ? loads[1] : 0, n > 2 ? loads[2] : 0)
    }
}
