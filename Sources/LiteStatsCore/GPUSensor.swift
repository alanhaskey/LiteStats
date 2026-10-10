// GPU 传感器：IOKit IOAccelerator → PerformanceStatistics。
//
// 性能关键点：
// 1) `io_service_t` 只在第一次查找（IOServiceGetMatchingServices 会遍历 IORegistry，代价高），
//    之后每拍只读一个属性（实测 0.018 ms）。绝不要每拍重新枚举 IORegistry。
// 2) 读属性要用 `IORegistryEntryCreateCFProperty("PerformanceStatistics")`，
//    不要用 `IORegistryEntryCreateCFProperties`（会把 IOReportLegend/SurfaceList 等
//    大块数据全部搬到用户态，实测 0.90 ms，慢 50 倍）。
import Foundation
import IOKit

final class GPUSensor {
    /// 匹配的服务类名（默认 IOAccelerator；测试里可以传一个不存在的类名来验证降级路径）。
    private let serviceClass: String

    /// 缓存的服务句柄；0 表示当前没有可用句柄（会在下一次刷新时重查）。
    private var service: io_service_t = 0
    private var serviceName: String?

    /// 最近一次成功读到的值；取不到时原样返回，绝不把 nil 变成 0。
    private var lastStats: GPUStats = .unavailable

    /// 查找失败的退避：避免在没有 IOAccelerator 的机器上每拍都全量枚举 IORegistry。
    private var lastLookupTick = Int.min
    private let lookupRetryTicks = 10

    var isAvailable: Bool { service != 0 }

    init(serviceClass: String = "IOAccelerator") {
        self.serviceClass = serviceClass
    }

    deinit {
        closeService()
    }

    /// 采一拍。`tick` 是调用方的单调递增计数，仅用于失败退避。
    func sample(tick: Int) -> GPUStats {
        if service == 0 {
            // 失败后至少隔 lookupRetryTicks 拍再重查。
            if tick != Int.min, lastLookupTick != Int.min, tick - lastLookupTick < lookupRetryTicks {
                return lastStats
            }
            lastLookupTick = tick
            guard let name = openService() else { return lastStats }
            serviceName = name
        }

        if let stats = readStats() {
            lastStats = stats
            return stats
        }

        // 读取失败：句柄可能已失效（GPU 复位 / 睡眠唤醒后的对象替换），
        // 释放后下一拍重新查找；这一拍返回上次的值。
        closeService()
        return lastStats
    }

    // MARK: - IOKit

    /// 查找 IOAccelerator 服务。优先选能读出 `Device Utilization %` 的那个
    /// （多 GPU / 多 accelerator 时），并把它的 marketing name 记下来。
    private func openService() -> String? {
        // IOServiceMatching 返回 +1 的字典，所有权移交给 IOServiceGetMatchingServices，不要自己 release。
        guard let matching = IOServiceMatching(serviceClass) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var fallback: io_service_t = 0
        var fallbackName: String?

        var candidate = IOIteratorNext(iterator)
        while candidate != 0 {
            let perf = Self.copyPerformanceStatistics(candidate)
            if let perf, perf["Device Utilization %"] != nil {
                // 找到可用的，释放之前留的兜底句柄。
                if fallback != 0 { IOObjectRelease(fallback) }
                service = candidate
                return Self.copyStringProperty(candidate, "model")
            }
            if fallback == 0 {
                fallback = candidate
                fallbackName = Self.copyStringProperty(candidate, "model")
            } else {
                IOObjectRelease(candidate)
            }
            candidate = IOIteratorNext(iterator)
        }

        service = fallback
        return fallback == 0 ? nil : fallbackName
    }

    private func closeService() {
        if service != 0 {
            IOObjectRelease(service)
            service = 0
        }
        serviceName = nil
    }

    /// 从缓存句柄读 PerformanceStatistics 组装 GPUStats。
    /// 返回 nil 只表示"这一次读失败"（调用方会释放句柄）；字段缺失时返回 nil 字段。
    private func readStats() -> GPUStats? {
        guard service != 0, let perf = Self.copyPerformanceStatistics(service) else { return nil }

        // "Device Utilization %" 实测是 0...100 的整数。
        var utilization: Double?
        if let raw = Self.number(perf["Device Utilization %"]) {
            utilization = clamp01(raw / 100.0)
        }

        let inUse = Self.number(perf["In use system memory"]).map { UInt64(max($0, 0)) }
        // 实测这台机器（AGXAcceleratorG17X）用的 key 是 "Alloc system memory"；
        // 其它驱动版本可能叫 "Allocated system memory"，两个都试。
        let allocated = (Self.number(perf["Alloc system memory"])
                         ?? Self.number(perf["Allocated system memory"])).map { UInt64(max($0, 0)) }

        return GPUStats(name: serviceName, utilization: utilization,
                        inUseMemory: inUse, allocatedMemory: allocated)
    }

    /// 只读 `PerformanceStatistics` 这一个属性。
    ///
    /// 坑（性能关键）：不要用 `IORegistryEntryCreateCFProperties` 读**全部**属性 ——
    /// 那会把 IOReportLegend / SurfaceList / AGCInfo 等大块数据一起搬到用户态，
    /// 实测 0.90 ms；只取一个属性只要 0.018 ms（快 50 倍）。
    private static func copyPerformanceStatistics(_ service: io_service_t) -> [String: Any]? {
        guard let value = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue() as? [String: Any]
    }

    private static func copyStringProperty(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                          kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue() as? String
    }

    /// CFNumber → Double（字典里可能是 Int / Int64 / Double）。
    private static func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}
