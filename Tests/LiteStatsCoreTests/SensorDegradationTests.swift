// 传感器降级与底层读取的冒烟测试：GPU 取不到时必须优雅降级为 nil（绝不崩、绝不当成 0），
// 网络接口索引必须来自 sockaddr_dl（而不是 if_nametoindex）。
// 这些测试会调用真实系统接口，但不断言任何易变的具体数值。
import Darwin
import Foundation
import Testing
@testable import LiteStatsCore

@Suite("传感器降级")
struct SensorDegradationTests {
    /// 匹配不到 IOAccelerator 时必须返回 unavailable（utilization = nil），
    /// 且后续调用不崩、不反复枚举 IORegistry（走退避）。
    @Test func gpuSensorDegradesToNilWhenServiceMissing() {
        let sensor = GPUSensor(serviceClass: "LiteStatsNonexistentAccelerator")
        let first = sensor.sample(tick: 1)
        #expect(first == GPUStats.unavailable)
        #expect(first.utilization == nil)     // nil 不是 0
        #expect(first.name == nil)
        #expect(first.inUseMemory == nil)
        #expect(first.allocatedMemory == nil)
        #expect(sensor.isAvailable == false)

        // 退避窗口内的重复调用同样安全
        let second = sensor.sample(tick: 2)
        #expect(second == GPUStats.unavailable)
    }

    /// 真实 GPU：要么取到合法值，要么 nil；两者都不能越界或崩溃。
    @Test func gpuSensorValuesStayInRange() {
        let sensor = GPUSensor()
        for tick in 1...3 {
            let stats = sensor.sample(tick: tick)
            if let utilization = stats.utilization {
                #expect(utilization >= 0 && utilization <= 1)
            }
        }
    }

    /// 接口索引来自 AF_LINK 的 sockaddr_dl.sdl_index；IFMIB 读取对非法索引返回 nil。
    @Test func interfaceIndexAnd64BitCounters() throws {
        let interfaces = NetworkSensor.readInterfaces()
        #expect(!interfaces.isEmpty)
        #expect(interfaces.allSatisfy { !$0.name.isEmpty })

        // 索引 0 非法 → nil（不抛错、不崩）
        #expect(NetworkSensor.read64BitCounters(index: 0) == nil)

        if let en0 = interfaces.first(where: { $0.name == "en0" }) {
            #expect(en0.index > 0)                       // sdl_index 提取正确
            #expect(en0.isLoopback == false)
            let counters = try #require(NetworkSensor.read64BitCounters(index: en0.index),
                                        "IFMIB 应能读到 en0 的 64 位计数")
            #expect(counters.received > 0)               // en0 自开机以来必然有流量
            #expect(counters.sent > 0)
        }
    }

    /// 内存传感器：total 等于物理内存，各分项口径自洽。
    @Test func memorySensorIsConsistent() {
        let memory = MemorySensor().sample()
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.used <= memory.total)
        #expect(memory.usage >= 0 && memory.usage <= 1)
        #expect(memory.free <= memory.total)
    }

    /// 磁盘传感器：容量结构自洽（used + free == total）。
    @Test func diskSensorIsConsistent() throws {
        let disk = try #require(DiskSensor().sample(), "statfs(\"/\") 不应该失败")
        #expect(disk.total > 0)
        #expect(disk.free <= disk.total)
        #expect(disk.used + disk.free == disk.total)
        #expect(disk.usage >= 0 && disk.usage <= 1)
    }
}
