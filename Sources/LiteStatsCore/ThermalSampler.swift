// 温度 / 风扇采样器：把 HID 温度 + AppleSMC 风扇拼成一个 ThermalStats。
//
// 设计要点：
// 1) 优雅降级：任何一步失败都返回 `.unavailable`（sourceDescription == nil），绝不抛错/崩溃。
// 2) 句柄复用：HID 客户端 / SMC 连接 / 服务列表都在进程生命周期内复用，只有失败才重建
//    （见 ThermalHIDReader / SMCReader 里的失败退避）。
// 3) 「代表温度」与过滤规则都在纯函数 `assemble` 里，便于单测（不碰硬件）。
//
// ⚠️ 去重：HID 会把同一个传感器名暴露成多个服务（本机 "PMU tdie4" 出现 2 次、
// "gas gauge battery" 出现 5 次），而冻结契约里 `ThermalSensor.id == name`。
// 若原样保留重复项，SwiftUI `ForEach` 会因为重复 id 出现渲染异常/丢行。因此这里按 name
// 去重并保留**最大值**（最大值不丢信息：cpuTemperature 本来就取最大值）。
import Foundation

/// 温度分组规则（纯函数）。
enum ThermalClassifier {
    /// 有效温度范围：严格大于 0 且不超过 125°C。
    /// * <= 0：`PMU tdev*` 未接槽位返回 -9199 ~ -9203，0 则是"未初始化"占位；
    /// * > 125：超过任何 Apple 芯片结温上限。
    static func isValid(_ celsius: Double) -> Bool {
        celsius.isFinite && celsius > 0 && celsius <= 125
    }

    /// 按传感器名分组。规则按顺序匹配（先 GPU，再 SoC，再存储，再电池，剩下 other）。
    static func group(for name: String) -> ThermalGroup {
        let lower = name.lowercased()
        if lower.contains("gpu") { return .gpu }                       // 本机没有，永远为空
        if name.hasPrefix("PMU tdie") || name.hasPrefix("PMU tcal") { return .cpu }
        // 未接槽位：读数必是 -9200 级垃圾（已被 isValid 过滤），归类 other 只是兜底。
        if name.hasPrefix("PMU tdev") { return .other }
        if name.hasPrefix("PMU t") { return .cpu }                     // 其它 PMU 温标当作 SoC
        if lower.contains("nand") || lower.contains("ssd") { return .storage }
        if lower.contains("battery") || name.hasPrefix("TB") || name.hasPrefix("Ts") {
            return .battery                                             // TB0T / Ts0P
        }
        return .other
    }
}

extension ThermalStats {
    /// 纯函数装配：过滤 → 按 name 去重（保留最大值）→ 分组 → 按 name 排序 → 算代表温度。
    ///
    /// - Parameters:
    ///   - hidRaw: HID 原始读数（含垃圾值，未过滤）
    ///   - smcRawTemperatures: 仅在 HID 完全失败时用于兜底的 SMC 温度键（正常情况下为空）
    ///   - fans: SMC 风扇读数
    ///   - readMillis: 本次读取耗时（毫秒）
    static func assemble(hidRaw: [RawThermalReading], smcRawTemperatures: [RawThermalReading],
                         fans: [FanReading], readMillis: Double) -> ThermalStats {
        var parts: [String] = []
        if !hidRaw.isEmpty { parts.append("HID(\(hidRaw.count) 个传感器)") }
        var smcParts: [String] = []
        if !fans.isEmpty { smcParts.append("\(fans.count) 个风扇") }
        if !smcRawTemperatures.isEmpty { smcParts.append("\(smcRawTemperatures.count) 个温度") }
        if !smcParts.isEmpty { parts.append("SMC(\(smcParts.joined(separator: " + ")))") }

        // HID 与 SMC 都没给出任何可用数据 → 严格返回冻结契约里的 .unavailable。
        guard !parts.isEmpty else { return .unavailable }

        // 过滤 + 去重（同名保留最大值）。Dictionary 的 value 用 (celsius, group)。
        var byName: [String: Double] = [:]
        for reading in hidRaw + smcRawTemperatures where ThermalClassifier.isValid(reading.celsius) {
            if let existing = byName[reading.name] {
                byName[reading.name] = max(existing, reading.celsius)
            } else {
                byName[reading.name] = reading.celsius
            }
        }

        let sensors = byName
            .map { ThermalSensor(name: $0.key, celsius: $0.value,
                                 group: ThermalClassifier.group(for: $0.key)) }
            .sorted { $0.name < $1.name }   // 按 name 排序，便于设置界面稳定展示

        func maximum(_ group: ThermalGroup) -> Double? {
            sensors.filter { $0.group == group }.map(\.celsius).max()
        }

        return ThermalStats(cpuTemperature: maximum(.cpu),
                            gpuTemperature: maximum(.gpu),
                            batteryTemperature: maximum(.battery),
                            sensors: sensors,
                            fans: fans,
                            sourceDescription: parts.joined(separator: " + "),
                            readMillis: readMillis)
    }
}

/// 线程安全：只在 `SystemMonitor` 的锁内使用，自身不加锁。
final class ThermalSampler {
    private let hid: ThermalHIDReader
    private let smc: SMCReader

    /// 实际完成的读取次数（被 SystemMonitor 隔拍复用时**不会**增加）。
    /// 仅供测试验证"隔 N 拍才真读一次"的契约。
    private(set) var readCount = 0

    init(hid: ThermalHIDReader = ThermalHIDReader(), smc: SMCReader = SMCReader()) {
        self.hid = hid
        self.smc = smc
    }

    /// 读一拍。`tick` 是 SystemMonitor 的单调递增计数，仅用于失败退避。
    func sample(tick: Int) -> ThermalStats {
        let begin = DispatchTime.now().uptimeNanoseconds
        readCount &+= 1

        let hidRaw = hid.read(tick: tick)

        var fans: [FanReading] = []
        var smcTemperatures: [RawThermalReading] = []
        if smc.ensureOpen(tick: tick) {
            fans = smc.fanReadings()
            // 只在 HID 完全读不出时才花时间读 SMC 温度键（正常路径零额外开销）。
            if hidRaw == nil {
                smcTemperatures = smc.fallbackTemperatures()
            }
        }

        let millis = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
        return ThermalStats.assemble(hidRaw: hidRaw ?? [],
                                     smcRawTemperatures: smcTemperatures,
                                     fans: fans,
                                     readMillis: millis)
    }
}
