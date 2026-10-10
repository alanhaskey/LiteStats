// 泄漏压测：这个项目的卖点就是"常驻开销低"，所以"每拍是否泄漏"必须有回归测试。
//
// 背景：一次 12000 拍的探针压测发现 RSS 从 9.4 MB 涨到 12.2 MB（≈244 B/拍），
// 怀疑是 host_processor_info 的 vm 内存没释放干净。本测试逐传感器定位。
//
// ⚠️ 阈值必须放得很宽：swift-testing 默认**并行**跑各 suite，而温度测试会做 HID/SMC 发现、
// 一次性分配好几 MB，直接把本 suite 测到的 RSS 抬高（实测 CPUSensor 从 2.5 B/拍 变成 288 B/拍）。
// 所以这里只抓"灾难性泄漏"（每拍 KB 量级），**权威测量在 `scripts/soak.sh`**
// —— 它把传感器层单独编译成一个进程跑，没有并行干扰。
import Foundation
import Testing

@testable import LiteStatsCore

@Suite(.serialized)
struct LeakSoakTests {
    private static func rssBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        return withUnsafeMutablePointer(to: &info) { pointer -> Int64 in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: integer_t.self)
            guard task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count) == KERN_SUCCESS else {
                return 0
            }
            return Int64(pointer.pointee.resident_size)
        }
    }

    /// 跑 `iterations` 拍，返回每拍 RSS 增长字节数
    private static func growthPerSample(_ label: String, warmup: Int = 300, iterations: Int = 20_000,
                                        _ body: () -> Void) -> Double {
        for _ in 0..<warmup { body() }
        let before = rssBytes()
        for _ in 0..<iterations { body() }
        let after = rssBytes()
        let perSample = Double(after - before) / Double(iterations)
        print(String(format: "[soak] %@: %d 拍 RSS %+.2f MB → %.1f B/拍",
                     label, iterations, Double(after - before) / 1_048_576, perSample))
        return perSample
    }

    @Test func cpuSensorDoesNotLeak() {
        let sensor = CPUSensor()
        let perSample = Self.growthPerSample("CPUSensor") { _ = sensor.sample() }
        #expect(perSample < 2048, "CPUSensor 每拍增长 \(perSample) 字节，疑似 vm_deallocate 没覆盖全部内存（权威检查：scripts/soak.sh）")
    }

    @Test func networkSensorDoesNotLeak() {
        let sensor = NetworkSensor()
        let perSample = Self.growthPerSample("NetworkSensor") { _ = sensor.sample(now: 0) }
        #expect(perSample < 2048, "NetworkSensor 每拍增长 \(perSample) 字节（权威检查：scripts/soak.sh）")
    }

    @Test func gpuSensorDoesNotLeak() {
        let sensor = GPUSensor()
        var tick = 0
        let perSample = Self.growthPerSample("GPUSensor") {
            tick += 1
            _ = sensor.sample(tick: tick)
        }
        #expect(perSample < 2048, "GPUSensor 每拍增长 \(perSample) 字节（权威检查：scripts/soak.sh）")
    }

    @Test func fullMonitorDoesNotLeak() {
        let monitor = SystemMonitor()
        let perSample = Self.growthPerSample("SystemMonitor(全部传感器)", iterations: 10_000) {
            _ = monitor.sample()
        }
        #expect(perSample < 2048, "SystemMonitor 每拍增长 \(perSample) 字节，疑似有传感器泄漏（权威检查：scripts/soak.sh）")
    }
}
