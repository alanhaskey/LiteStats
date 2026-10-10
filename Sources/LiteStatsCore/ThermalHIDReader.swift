// 温度传感器：私有 HID 接口（IOHIDEventSystemClient，client type = 1 Admin）。
//
// ## 为什么必须用 type = 1（Admin）而不是 type = 2（Monitor）
// 实测本机（macOS 27.0.1 / Apple M5 Pro）：type=2 用同样的匹配字典也能匹配到 77 个服务，
// 但对每个服务调 `IOHIDServiceClientCopyEvent(service, 15, ...)` 全部返回 NULL ——
// 一个温度读数都拿不到；换成 type=1 能读出 76/77 个（唯一没有读数的是 "als-temp" 环境光
// 传感器，它本来就不上报 temperature 事件）。所以这里硬编码 1
// （私有 IOHIDEventSystemClient.h 里 kIOHIDEventSystemClientTypeAdmin = 1，Monitor = 2）。
//
// ## 为什么要过滤读数（关键坑）
// "PMU tdev*"（本机 24 个可读槽位）是**未接**的传感器槽位，读数恒为 -9199 ~ -9203°C 之类的
// 垃圾值。不过滤的话设置界面会出现 -9201°C。本文件只接受 (0, 125] °C：
//   * <= 0：负数/零都视为"未接或未初始化"，真实 SoC 温度不可能恰好是 0；
//   * > 125：超过任何 Apple 芯片结温上限（SoC 会在 ~105°C 降频、~110°C 关机）。
//
// ## 符号来源
// 这些是 IOKit 导出、但不在公开头文件里的私有符号，用 `@_silgen_name` 声明即可；
// 实测可编译可链接，不需要额外的 linker flag。
//
// ## 性能（实测，和"读 76 个传感器只要 2ms"的直觉相反）
// 本机实测 type=1 客户端**每次** `IOHIDServiceClientCopyEvent` 都是 ~0.75–1.2ms 的固定
// IPC 往返（同一个服务连读 10 次也一样），所以 76 个服务全量扫一遍要 **65–80ms**；
// IOKit 里也没有批量接口（dlsym 探过，没有 IOHIDEventSystemClientCopyEvent /
// IOHIDServiceClientCopyEvents）。按默认 5 拍刷一次 = 60ms/5s ≈ 1.2% 单核，会破坏
// 0.1% 的常驻开销预算。因此这里做**时间盒切片**：
//   * 每次 read() 最多花 `readBudgetMillis`（默认 5ms，含最后一次调用的过冲 ~1.2ms）
//     去读服务，机器忙时少读几个、空闲时多读几个 —— 硬保证单次读取 <10ms；
//   * 服务按「同名实例交错」排序：先每个传感器名各读 1 份实例，再读第 2 份……
//     这样每个**名字**在几次刷新内被采样到，代表温度（最大值）的新鲜度只取决于
//     唯一名字数，不受同名实例数量拖累；
//   * 没被本次读到的传感器沿用上一次的值（latest），所以 sensors 列表不会缩水；
//   * 想恢复"每次全量读"，把 readBudgetMillis 传成 .infinity 即可（代价：~70ms/次）。
//
// ## 性能（句柄）
// HID 客户端与 `IOHIDEventSystemClientCopyServices` 的服务列表在进程生命周期内复用，
// 只有读取失败时才释放重建 —— 等价于 GPUSensor 的句柄缓存 + 失败退避。
import Foundation
import IOKit

// MARK: - 私有符号声明

@_silgen_name("IOHIDEventSystemClientCreateWithType")
private func IOHIDEventSystemClientCreateWithType(_ allocator: CFAllocator?,
                                                  _ type: UInt32,
                                                  _ options: CFDictionary?) -> CFTypeRef?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef,
                                               _ matching: CFDictionary?) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef,
                                            _ key: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int32,
                                         _ options: Int64, _ timestamp: Int64) -> CFTypeRef?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

// MARK: - 原始读数

/// 未经过滤的原始读数（可能包含 -9201°C 这类垃圾）。过滤/分类在 ThermalStats.assemble 里做。
struct RawThermalReading: Equatable {
    let name: String
    let celsius: Double
}

// MARK: - 读取器

/// 线程安全：只在 `SystemMonitor` 的锁内使用，自身不加锁。
final class ThermalHIDReader {
    /// kIOHIDEventSystemClientTypeAdmin。type=2 (Monitor) 读不出温度（见文件头注释）。
    static let adminClientType: UInt32 = 1
    /// kIOHIDEventTypeTemperature
    private static let temperatureEventType: Int32 = 15
    /// 温度字段 = kIOHIDEventFieldTemperatureLevel = (type << 16)
    private static let temperatureField: Int32 = Int32(15 << 16)

    private let clientType: UInt32
    private let usagePage: Int
    private let usage: Int
    /// 单次 read() 读服务的时间预算（纳秒）。见文件头「性能」。
    private let readBudgetNanos: UInt64

    /// 缓存的 HID 客户端（+1，ARC 管理）。
    private var client: CFTypeRef?
    /// 缓存的 (服务句柄, 传感器名) 列表：名字只在建立句柄时读一次（Product 属性不会变）。
    /// 顺序 = 「同名实例交错」后的轮转顺序。
    private var entries: [(service: AnyObject, name: String)] = []
    /// 每个服务最近一次读到的原始值（含 -9201 这类垃圾，过滤在 ThermalStats.assemble）。
    private var latest: [Double?] = []
    /// 轮转游标：下一次从哪个服务开始读。
    private var cursor = 0
    /// 连续"整片一个读数都没读到"的次数：累计到 3 次就认为句柄已失效（睡眠唤醒后对象被
    /// 替换）→ 释放重建。用整片成功率而不是"累计失败数"来判断，是因为时间盒切片每次只读
    /// 几个服务，逐个计数要很久才能发现句柄死掉。
    private var emptySlices = 0

    /// 查找失败的退避（照抄 GPUSensor）：避免在没有 HID 温度传感器的机器上每拍全量枚举。
    private var lastLookupTick = Int.min
    private let lookupRetryTicks = 10

    /// 测试可以传一个不存在的 usagePage 来验证降级路径；clientType 可传 2 复现"读不出"。
    /// readBudgetMillis 传 .infinity 等于每次全量读（约 70ms，只在诊断时用）。
    init(clientType: UInt32 = ThermalHIDReader.adminClientType,
         usagePage: Int = 0xff00, usage: Int = 5, readBudgetMillis: Double = 5.0) {
        self.clientType = clientType
        self.usagePage = usagePage
        self.usage = usage
        if readBudgetMillis.isFinite, readBudgetMillis > 0 {
            self.readBudgetNanos = UInt64(readBudgetMillis * 1_000_000)
        } else {
            self.readBudgetNanos = .max
        }
    }

    deinit { close() }

    var isAvailable: Bool { client != nil && !entries.isEmpty }

    /// 已发现的温度服务数量（含尚未轮到读取的）。仅测试与诊断使用。
    var discoveredServiceCount: Int { entries.count }

    /// 读一次温度传感器。`tick` 是调用方的单调递增计数，仅用于失败退避。
    ///
    /// 返回值包含**本次切片读到的 + 之前读到过的**全部原始读数（含垃圾值），
    /// 过滤交给 ThermalStats.assemble（这样过滤规则可单测）。
    /// 返回 nil 表示"完全没有可用数据"（调用方不会把它当 0）。
    func read(tick: Int) -> [RawThermalReading]? {
        if client == nil || entries.isEmpty {
            // 失败后至少隔 lookupRetryTicks 拍再重查。
            if lastLookupTick != Int.min, tick - lastLookupTick < lookupRetryTicks {
                return nil
            }
            lastLookupTick = tick
            guard open() else {
                close()
                return nil
            }
        }

        // 时间盒切片：至少读 1 个服务，最多把整个列表读一遍；
        // 每次服务调用 ~0.9–1.2ms，所以 5ms 预算通常读 4–6 个，过冲不超过一次调用。
        // 注意：readBudgetNanos == .max（不限预算 / 诊断用全量读）时不能让 deadline
        // 溢出回绕，否则第一次循环就 break，只能读到一个服务。
        let deadline = readBudgetNanos == .max
            ? UInt64.max
            : DispatchTime.now().uptimeNanoseconds &+ readBudgetNanos
        var successes = 0
        for _ in 0..<entries.count {
            let index = cursor
            cursor = (cursor + 1) % entries.count
            if let event = IOHIDServiceClientCopyEvent(entries[index].service,
                                                       Self.temperatureEventType, 0, 0) {
                let value = IOHIDEventGetFloatValue(event, Self.temperatureField)
                if value.isFinite {
                    latest[index] = value
                    successes += 1
                }
            }
            // CopyEvent 返回 nil 是正常情况：als-temp（环境光）这类服务不上报 temperature。
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
        }

        if successes == 0 {
            emptySlices += 1
            if emptySlices >= 3 {
                // 连续三片都读不到任何读数：句柄大概已失效 → 释放，退避后重建。
                close()
                return nil
            }
        } else {
            emptySlices = 0
        }

        var readings: [RawThermalReading] = []
        readings.reserveCapacity(entries.count)
        for index in entries.indices {
            guard let value = latest[index] else { continue }   // 还没轮到过的服务
            readings.append(RawThermalReading(name: entries[index].name, celsius: value))
        }
        return readings.isEmpty ? nil : readings
    }

    // MARK: - 句柄生命周期

    /// 建立 HID 客户端并缓存服务列表。成功返回 true。
    private func open() -> Bool {
        guard let newClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault,
                                                                   clientType, nil) else {
            return false
        }
        // 匹配字典：温度传感器 = PrimaryUsagePage 0xff00 / PrimaryUsage 5。
        let matching: [String: Any] = ["PrimaryUsagePage": usagePage, "PrimaryUsage": usage]
        // 坑：实测 SetMatching 的返回值非 0（本机 75387696）但依然能拿到 77 个服务，
        // 所以**不能**用它判断成败，只能看下面的服务数量。
        _ = IOHIDEventSystemClientSetMatching(newClient, matching as CFDictionary)
        guard let array = IOHIDEventSystemClientCopyServices(newClient) else { return false }
        // CFArray ↔ NSArray toll-free bridge：元素（IOHIDServiceClient）由 Swift 数组持有。
        let services = array as [AnyObject]
        guard !services.isEmpty else { return false }

        var raw: [(service: AnyObject, name: String)] = []
        raw.reserveCapacity(services.count)
        for (index, service) in services.enumerated() {
            let product = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
            // 没有 Product 属性的服务用下标兜底命名，保证 name 非空（id == name 不能为空）。
            raw.append((service, product ?? "HID sensor #\(index)"))
        }

        close()
        client = newClient
        entries = Self.interleaveByName(raw)
        latest = [Double?](repeating: nil, count: entries.count)
        cursor = 0
        emptySlices = 0
        return true
    }

    private func close() {
        // ARC 会释放 CFTypeRef（Create/Copy 系列返回 +1，所有权已转移给 Swift）。
        client = nil
        entries = []
        latest = []
        cursor = 0
        emptySlices = 0
    }

    /// 重排服务，决定轮转切片的读取顺序。两条规则：
    ///
    /// 1) **名字优先级**：先每组挑一个"代表名"（CPU → GPU → 电池 → 硬盘 各挑第一个出现的），
    ///    再放 CPU 组剩下的名字，最后才是其余名字（含未接的 "PMU tdev*" 槽位）。
    ///    这样时间盒切片即使只读到 3 个服务（首拍就 ~4 个），CPU / 电池 / 硬盘三个代表温度
    ///    也已经在第一拍里；CPU 代表温度取最大值，所以 cpu 组名字排在第二位优先。
    /// 2) **同名实例交错**：同一名字的第 0 份实例全部排在前，再排第 1 份……
    ///    HID 会把同一个传感器名暴露成多个服务（本机 "PMU tdie4" 3 份、
    ///    "gas gauge battery" 6 份），交错排序保证任意一个切片覆盖的**名字**尽可能多 ——
    ///    代表温度的新鲜度因此只受"唯一名字数"影响，不受同名实例数量的拖累。
    static func interleaveByName<T>(_ items: [(service: T, name: String)])
        -> [(service: T, name: String)] {
        var appearance: [String] = []
        var byName: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            if byName[item.name] == nil { appearance.append(item.name) }
            byName[item.name, default: []].append(index)
        }

        // 规则 1：代表名优先 → CPU 组其余名字 → 其它。
        let groupOf: (String) -> ThermalGroup = { ThermalClassifier.group(for: $0) }
        var representatives: [String] = []
        for group in [ThermalGroup.cpu, .gpu, .battery, .storage] {
            if let name = appearance.first(where: { groupOf($0) == group }) {
                representatives.append(name)
            }
        }
        let cpuRest = appearance.filter { groupOf($0) == .cpu && !representatives.contains($0) }
        let rest = appearance.filter { groupOf($0) != .cpu && !representatives.contains($0) }
        let orderedNames = representatives + cpuRest + rest

        // 规则 2：按"实例轮次"交错。
        var result: [(service: T, name: String)] = []
        result.reserveCapacity(items.count)
        let rounds = byName.values.map(\.count).max() ?? 0
        for round in 0..<rounds {
            for name in orderedNames {
                guard let indexes = byName[name], indexes.count > round else { continue }
                result.append(items[indexes[round]])
            }
        }
        return result
    }
}
