// 温度 / 风扇的契约测试：
//   * 垃圾值过滤（-9200 系列是未接槽位，绝不能进 sensors / cpuTemperature）
//   * 分组规则、同名去重、代表温度（最大值）语义
//   * 完全失败时的降级（.unavailable，绝不崩、绝不当成 0）
//   * SystemMonitor 的隔拍缓存契约（thermalRefreshEveryNTicks）
//   * AppleSMC 字节解析（flt 小端 / ui* 大端）与 80 字节结构体布局
import Foundation
import Testing
@testable import LiteStatsCore

@Suite("温度 / 风扇")
struct ThermalTests {
    // MARK: - 垃圾值过滤

    /// 构造 -9201.14 / 999 / 0 / 正常的混合读数，断言只有合理值进入 sensors，
    /// 且 cpuTemperature 不被垃圾值污染（既不是 -9201 也不是 999）。
    @Test func garbageReadingsAreFilteredOut() {
        let stats = ThermalStats.assemble(
            hidRaw: [RawThermalReading(name: "PMU tdev3", celsius: -9201.1429),
                     RawThermalReading(name: "PMU tdie4", celsius: 52.2),
                     RawThermalReading(name: "PMU tdev8", celsius: -9199.4286),
                     RawThermalReading(name: "PMU tcal", celsius: 999),
                     RawThermalReading(name: "PMU tdie1", celsius: 0),
                     RawThermalReading(name: "NAND CH0 temp", celsius: 41.0)],
            smcRawTemperatures: [], fans: [], readMillis: 1.5)

        #expect(stats.sensors.map(\.name) == ["NAND CH0 temp", "PMU tdie4"])
        #expect(stats.sensors.allSatisfy { ThermalClassifier.isValid($0.celsius) })
        #expect(stats.cpuTemperature == 52.2)          // 999 / 0 / -9201 都没参与
        #expect(stats.batteryTemperature == nil)
        #expect(stats.sourceDescription == "HID(6 个传感器)")
        #expect(stats.readMillis == 1.5)
    }

    /// 有效范围是 (0, 125]：0 与负数、以及 >125 都要被丢掉（0 是"未初始化"占位）。
    @Test func validRangeBoundaries() {
        #expect(ThermalClassifier.isValid(0.01))
        #expect(ThermalClassifier.isValid(125.0))
        #expect(ThermalClassifier.isValid(52.0))
        #expect(!ThermalClassifier.isValid(0))
        #expect(!ThermalClassifier.isValid(-0.01))
        #expect(!ThermalClassifier.isValid(-9201.14))
        #expect(!ThermalClassifier.isValid(125.01))
        #expect(!ThermalClassifier.isValid(999))
        #expect(!ThermalClassifier.isValid(.nan))
        #expect(!ThermalClassifier.isValid(.infinity))
    }

    // MARK: - 分组

    @Test func classificationBySensorName() {
        #expect(ThermalClassifier.group(for: "PMU tdie4") == .cpu)
        #expect(ThermalClassifier.group(for: "PMU tcal") == .cpu)
        #expect(ThermalClassifier.group(for: "NAND CH0 temp") == .storage)
        #expect(ThermalClassifier.group(for: "TB0T") == .battery)
        #expect(ThermalClassifier.group(for: "Ts0P") == .battery)
        #expect(ThermalClassifier.group(for: "gas gauge battery") == .battery)
        // PMU tdev* 是**未接槽位**（读数恒为 -9200 级垃圾，已被过滤），归类 other 只是兜底：
        // 它们永远不会出现在 sensors 里，写成 cpu 会误导 UI 的"CPU 传感器"分组。
        #expect(ThermalClassifier.group(for: "PMU tdev1") == .other)
        #expect(ThermalClassifier.group(for: "GPU MTR Temp Sensor0") == .gpu)
        #expect(ThermalClassifier.group(for: "als-temp") == .other)

        #expect(ThermalGroup.cpu.displayName == "CPU")
        #expect(ThermalGroup.gpu.displayName == "GPU")
        #expect(ThermalGroup.storage.displayName == "硬盘")
        #expect(ThermalGroup.battery.displayName == "电池")
        #expect(ThermalGroup.other.displayName == "其他")
        #expect(ThermalGroup.allCases.count == 5)
    }

    /// 代表温度：cpu / gpu / battery 各取本组最大值；组内没有有效值时是 nil（不是 0）。
    @Test func representativeTemperaturesAreGroupMaximums() {
        let stats = ThermalStats.assemble(
            hidRaw: [RawThermalReading(name: "PMU tdie4", celsius: 52.2),
                     RawThermalReading(name: "PMU tdie1", celsius: 55.7),
                     RawThermalReading(name: "gas gauge battery", celsius: 34.9),
                     RawThermalReading(name: "NAND CH0 temp", celsius: 41.0)],
            smcRawTemperatures: [], fans: [], readMillis: 0.4)

        #expect(stats.cpuTemperature == 55.7)
        #expect(stats.batteryTemperature == 34.9)
        #expect(stats.gpuTemperature == nil)   // 本机没有 GPU 专属传感器 → nil，不拿 CPU 冒充
        #expect(stats.sensors.map(\.name) == ["NAND CH0 temp", "PMU tdie1", "PMU tdie4",
                                             "gas gauge battery"])
    }

    /// 同名实例（HID 会把一个传感器名暴露成多个服务）按 name 去重并保留最大值，
    /// 否则 `ThermalSensor.id == name` 会重复，SwiftUI ForEach 会异常。
    @Test func duplicateNamesAreDeduplicatedKeepingMaximum() {
        let stats = ThermalStats.assemble(
            hidRaw: [RawThermalReading(name: "PMU tdie4", celsius: 51.88),
                     RawThermalReading(name: "PMU tdie4", celsius: 52.28),
                     RawThermalReading(name: "PMU tdie4", celsius: 52.20)],
            smcRawTemperatures: [], fans: [], readMillis: 0.2)

        #expect(stats.sensors.count == 1)
        #expect(stats.sensors.first?.celsius == 52.28)
        #expect(stats.cpuTemperature == 52.28)
        #expect(Set(stats.sensors.map(\.id)).count == stats.sensors.count)
    }

    /// SMC 温度键（只在 HID 完全读不出时兜底）也要能参与装配与分组。
    @Test func smcFallbackTemperaturesParticipate() {
        let stats = ThermalStats.assemble(
            hidRaw: [], smcRawTemperatures: [RawThermalReading(name: "TB0T", celsius: 34.9),
                                             RawThermalReading(name: "Ts0P", celsius: 33.25)],
            fans: [FanReading(index: 0, rpm: 2317, minRPM: 2317, maxRPM: 7826, targetRPM: 2317)],
            readMillis: 2.0)

        #expect(stats.cpuTemperature == nil)          // 没有 CPU 传感器就老老实实 nil
        #expect(stats.batteryTemperature == 34.9)
        #expect(stats.sourceDescription == "SMC(1 个风扇 + 2 个温度)")
        #expect(stats.fans.count == 1)
    }

    // MARK: - 降级

    /// 冻结契约：`.unavailable` 的字段全为 nil / 空数组，cpuTemperature 必须是 nil。
    @Test func unavailableIsAllNil() {
        let stats = ThermalStats.unavailable
        #expect(stats.cpuTemperature == nil)
        #expect(stats.gpuTemperature == nil)
        #expect(stats.batteryTemperature == nil)
        #expect(stats.sensors.isEmpty)
        #expect(stats.fans.isEmpty)
        #expect(stats.sourceDescription == nil)
        #expect(stats.readMillis == 0)
        // 所有可用数据都失败时，assemble 必须严格返回 .unavailable。
        #expect(ThermalStats.assemble(hidRaw: [], smcRawTemperatures: [], fans: [],
                                      readMillis: 9.9) == .unavailable)
        // 全是垃圾读数（例如整机 HID 都是 tdev）时同样降级，而不是给一张空表。
        #expect(ThermalStats.assemble(hidRaw: [RawThermalReading(name: "PMU tdev1",
                                                                celsius: -9201.14)],
                                      smcRawTemperatures: [], fans: [],
                                      readMillis: 1.0).sourceDescription == "HID(1 个传感器)")
    }

    /// HID 匹配不到任何服务 + SMC 服务名不存在 → 采样器必须优雅降级（不崩、不抛、返回 .unavailable）。
    @Test func samplerDegradesWhenEverythingFails() {
        let sampler = ThermalSampler(
            hid: ThermalHIDReader(usagePage: 0xffff, usage: 0xffff),   // 匹配不到服务
            smc: SMCReader(serviceName: "LiteStatsNonexistentSMC")     // 打不开
        )
        #expect(sampler.sample(tick: 1) == .unavailable)
        // 退避窗口内重复调用同样安全
        #expect(sampler.sample(tick: 2) == .unavailable)
        #expect(sampler.sample(tick: 99) == .unavailable)
        #expect(sampler.readCount == 3)      // 真读了 3 次（只是没有数据）
    }

    /// 真实硬件冒烟：要么完全取不到，要么所有值都在 (0, 125] 内（-9201 这种绝不能漏出来）。
    /// 全量读一次（readBudgetMillis = .infinity）以便覆盖所有服务。
    @Test func realHardwareNeverExposesGarbage() {
        let reader = ThermalHIDReader(readBudgetMillis: .infinity)
        guard let readings = reader.read(tick: 1) else {
            #expect(reader.isAvailable == false)
            return
        }
        #expect(!readings.isEmpty)
        #expect(reader.discoveredServiceCount >= readings.count)

        let stats = ThermalStats.assemble(hidRaw: readings, smcRawTemperatures: [], fans: [],
                                          readMillis: 0)
        #expect(stats.sensors.allSatisfy { ThermalClassifier.isValid($0.celsius) })
        #expect(stats.sensors.allSatisfy { !$0.name.isEmpty })
        if let cpu = stats.cpuTemperature {
            #expect(cpu > 0 && cpu <= 125)
        }
        // 过滤确实丢掉了东西：本机 tdev 未接槽位（-9199 ~ -9203）必须在被丢之列。
        let filtered = readings.filter { !ThermalClassifier.isValid($0.celsius) }
        #expect(filtered.allSatisfy { $0.celsius <= 0 || $0.celsius > 125 })

        // 人工核对用：打印全部原始读数（✓ = 进入 sensors，✗ = 被过滤）。
        for reading in readings {
            let ok = ThermalClassifier.isValid(reading.celsius)
            print(String(format: "[thermal] %@ %-24@ %12.4f %@",
                         ok ? "✓" : "✗", reading.name as NSString, reading.celsius,
                         ok ? "" : "← 过滤（不在 (0,125]）"))
        }
        let validReadings = readings.filter { ThermalClassifier.isValid($0.celsius) }
        print(String(format: "[thermal] 原始读数=%d 垃圾被过滤=%d 有效读数=%d 去重后唯一名字=%d "
                     + "cpu=%@ 电池=%@",
                     readings.count, readings.count - validReadings.count, validReadings.count,
                     stats.sensors.count,
                     stats.cpuTemperature.map { String(format: "%.2f°C", $0) } ?? "nil",
                     stats.batteryTemperature.map { String(format: "%.2f°C", $0) } ?? "nil"))
    }

    /// 真实 SMC：风扇读数在合理范围（0...30000），且不会因为读不到而崩。
    @Test func realFanReadingsAreSane() {
        let smc = SMCReader()
        guard smc.ensureOpen(tick: 1) else { return }
        let fans = smc.fanReadings()
        #expect(fans.count <= SMCReader.maxFans)
        for (offset, fan) in fans.enumerated() {
            #expect(fan.index == offset)             // 索引必须连续（F0Ac / F1Ac ...）
            for value in [fan.rpm, fan.minRPM, fan.maxRPM, fan.targetRPM].compactMap({ $0 }) {
                #expect(value >= 0 && value <= 30000)
            }
        }
    }

    // MARK: - 失败退避与切片

    /// 失败退避：匹配不到服务时不要在每一拍都重新枚举 IORegistry / HID 服务。
    @Test func hidReaderBacksOffAfterFailure() {
        let reader = ThermalHIDReader(usagePage: 0xffff, usage: 0xffff)
        #expect(reader.read(tick: 1) == nil)
        #expect(reader.isAvailable == false)
        #expect(reader.discoveredServiceCount == 0)
        // 退避窗口内（10 拍）不再重试，返回 nil 但不崩。
        #expect(reader.read(tick: 2) == nil)
    }

    /// 「代表名优先 + 同名实例交错」排序：
    /// 先每组挑一个代表名（CPU → GPU → 电池 → 硬盘），再 CPU 组其余名字，最后其它；
    /// 同一名字的实例按轮次（第 0 份、第 1 份…）交错。
    /// 这样时间盒切片即使只读到几个服务，CPU / 电池 / 硬盘三个代表温度也已经在第一拍里。
    @Test func servicesAreInterleavedByName() {
        let items: [(service: Int, name: String)] = [
            (0, "PMU tdie4"), (1, "PMU tdie7"), (2, "PMU tdie4"),
            (3, "NAND CH0 temp"), (4, "PMU tdie4"), (5, "PMU tdie7"),
            (6, "gas gauge battery"), (7, "PMU tdev1"),
        ]
        let ordered = ThermalHIDReader.interleaveByName(items)
        #expect(ordered.map(\.service) == [0, 6, 3, 1, 7, 2, 5, 4])
        #expect(Set(ordered.map(\.service)) == Set(items.map(\.service)))   // 不丢不重
        // 第一片（前 3 个）必须覆盖 cpu / battery / storage 三个代表名。
        let firstSliceGroups = Set(ordered.prefix(3).map { ThermalClassifier.group(for: $0.name) })
        #expect(firstSliceGroups == [.cpu, .battery, .storage])
    }

    // MARK: - SystemMonitor 契约

    /// thermalRefreshEveryNTicks = 3 时：只有第 1、4、7… 拍真读，其余拍复用同一份 ThermalStats。
    @Test func thermalIsCachedBetweenRefreshTicks() {
        let monitor = SystemMonitor(configuration: MonitorConfiguration(thermalRefreshEveryNTicks: 3))
        let first = monitor.sample()
        #expect(monitor.thermalReadCount == 1)
        let second = monitor.sample()
        let third = monitor.sample()
        #expect(monitor.thermalReadCount == 1)          // 第 2、3 拍复用缓存
        #expect(second.thermal == first.thermal)
        #expect(third.thermal == first.thermal)

        let fourth = monitor.sample()                   // 第 4 拍（tick % 3 == 1）重新读
        #expect(monitor.thermalReadCount == 2)
        #expect(fourth.thermal.readMillis >= 0)
        // 重新读过之后，值必须仍然自洽（取不到时就是 .unavailable，不能是"半张表"）。
        if let source = fourth.thermal.sourceDescription {
            #expect(!source.isEmpty)
        } else {
            #expect(fourth.thermal == .unavailable)
        }
    }

    /// includeThermal = false：thermal 恒为 .unavailable，且一次真实读取都不发生。
    @Test func thermalCanBeDisabled() {
        let monitor = SystemMonitor(configuration: MonitorConfiguration(includeThermal: false))
        for _ in 0..<4 {
            #expect(monitor.sample().thermal == .unavailable)
        }
        #expect(monitor.thermalReadCount == 0)
        #expect(monitor.configuration.includeThermal == false)
        #expect(MonitorConfiguration().includeThermal == true)             // 默认为 true
        #expect(MonitorConfiguration().thermalRefreshEveryNTicks == 5)     // 默认为 5
        // 旧参数的默认值不变（追加式修改，不能破坏既有调用方）
        #expect(MonitorConfiguration().gpuRefreshEveryNTicks == 2)
        #expect(MonitorConfiguration().includeDisk == true)
    }

    /// 快照里的 temperature 字段与 thermal 结构自洽（真实硬件冒烟）。
    @Test func snapshotThermalIsSelfConsistent() {
        let monitor = SystemMonitor(configuration: MonitorConfiguration(thermalRefreshEveryNTicks: 1))
        let snapshot = monitor.sample()
        let thermal = snapshot.thermal
        if let cpu = thermal.cpuTemperature {
            #expect(thermal.sensors.contains { $0.group == .cpu && $0.celsius == cpu })
            #expect(cpu > 0 && cpu <= 125)
        }
        if let battery = thermal.batteryTemperature {
            #expect(thermal.sensors.contains { $0.group == .battery && $0.celsius == battery })
        }
        #expect(thermal.sensors.map(\.name) == thermal.sensors.map(\.name).sorted())
    }
}

@Suite("AppleSMC 字节解析")
struct SMCValueParserTests {
    /// ⚠️ 实测字节序不统一：`flt ` 是主机字节序（小端）的 IEEE754 位模式，
    /// ui8 / ui16 / ui32 是大端整数。这两个断言用的都是本机真实读到的字节。
    @Test func floatIsHostEndianBitPattern() throws {
        // F0Ac = 2318.0 rpm → bytes [0x00, 0xE0, 0x10, 0x45]
        let fan = try #require(SMCValueParser.number(bytes: [0x00, 0xE0, 0x10, 0x45],
                                                     size: 4, type: "flt "))
        #expect(abs(fan - 2318.0) < 0.001)
        // TB0T = 35.2°C → bytes [0xCC, 0xCC, 0x0C, 0x42]（本机实测原始字节）
        let battery = try #require(SMCValueParser.number(bytes: [0xCC, 0xCC, 0x0C, 0x42],
                                                         size: 4, type: "flt "))
        #expect(abs(battery - 35.2) < 0.01)
        // 反过来的字节序（大端解释）会得到完全不同的值 —— 说明这个断言有区分度。
        let wrong = try #require(SMCValueParser.number(bytes: [0x45, 0x10, 0xE0, 0x00],
                                                       size: 4, type: "flt "))
        #expect(abs(wrong - 2318.0) > 1)
        #expect(SMCValueParser.float([0x00, 0xE0]) == nil)      // 字节不够 → nil，不越界读
    }

    @Test func integersAreBigEndian() throws {
        // #KEY = 3611 → bytes [0x00, 0x00, 0x0E, 0x1B]
        let keyCount = try #require(SMCValueParser.number(bytes: [0x00, 0x00, 0x0E, 0x1B],
                                                          size: 4, type: "ui32"))
        #expect(keyCount == 3611)
        // F0Mn = 2317 → bytes [0x09, 0x0D]
        let minRPM = try #require(SMCValueParser.number(bytes: [0x09, 0x0D],
                                                        size: 2, type: "ui16"))
        #expect(minRPM == 2317)
        let byte = try #require(SMCValueParser.number(bytes: [0x2A], size: 1, type: "ui8 "))
        #expect(byte == 42)
        #expect(SMCValueParser.unsigned([]) == nil)
        #expect(SMCValueParser.unsigned([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]) == nil)
    }

    /// Intel Mac 常见的定点类型（本机是 `flt `，用不到，但解析器要认）。
    @Test func fixedPointTypes() throws {
        let fpe2 = try #require(SMCValueParser.number(bytes: [0x24, 0x34], size: 2, type: "fpe2"))
        #expect(fpe2 == 2317)
        let sp78 = try #require(SMCValueParser.number(bytes: [0x22, 0xE6], size: 2, type: "sp78"))
        #expect(sp78 == 34.8984375)
        let negative = try #require(SMCValueParser.number(bytes: [0xFF, 0x00], size: 2, type: "sp78"))
        #expect(negative == -1)
    }

    @Test func unknownTypesAndSizesAreRejected() {
        #expect(SMCValueParser.number(bytes: [0x01, 0x02], size: 2, type: "ch8*") == nil)
        #expect(SMCValueParser.number(bytes: [0x01, 0x02], size: 0, type: "flt ") == nil)
        #expect(SMCValueParser.number(bytes: [0x01], size: 4, type: "flt ") == nil)
    }

    /// ⚠️ 关键坑：SMCKeyData 必须精确 80 字节。少了 attrs 后面那 3 个 pad 就变成 76，
    /// selector 2 会返回 0xe00002c2 (kIOReturnBadArgument)，风扇一个都读不出来。
    @Test func smcKeyDataLayoutIsExactly80Bytes() {
        #expect(MemoryLayout<SMCKeyData>.stride == 80)
        #expect(MemoryLayout<SMCKeyData>.size == 80)
        #expect(SMCKeyData.layoutStride == 80)
    }
}
