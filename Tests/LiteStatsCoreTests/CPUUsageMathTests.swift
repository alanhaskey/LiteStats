// CPUUsageMath 纯函数单测：正常两拍、32 位 tick 回绕、全 idle、满负载、
// 核心数为 0 / 数组长度不足 / 增量和为 0（除零保护）。
// 全部不碰硬件。
import Testing
@testable import LiteStatsCore

@Suite("CPUUsageMath")
struct CPUUsageMathTests {
    /// 正常两拍（2 核心）：手算结果。
    @Test func normalTwoSamples() {
        // 每核心 4 个 tick: user, system, idle, nice
        let previous: [UInt32] = [100, 50, 850, 0, 200, 100, 700, 0]
        let current: [UInt32] = [120, 60, 920, 0, 250, 120, 830, 0]
        let r = CPUUsageMath.compute(previous: previous, current: current, coreCount: 2)

        // core0: busy = (120-100) + (60-50) + nice0 = 30, sum = 100 → 0.30
        // core1: busy = 50 + 20 = 70, sum = 200 → 0.35
        #expect(abs(r.perCore[0] - 0.30) < 1e-9)
        #expect(abs(r.perCore[1] - 0.35) < 1e-9)
        // 总: user = 20+50 = 70, system = 10+20 = 30, idle = 70+130 = 200, all = 300
        #expect(abs(r.idle - 200.0 / 300.0) < 1e-9)
        #expect(abs(r.user - 70.0 / 300.0) < 1e-9)
        #expect(abs(r.system - 30.0 / 300.0) < 1e-9)
        #expect(abs(r.total - 100.0 / 300.0) < 1e-9)
        #expect(r.perCore.count == 2)
        #expect(abs(r.user + r.system + r.idle - 1) < 1e-9)
    }

    /// tick 32 位回绕：current < previous 时必须按 2^32 取模做差，而不是当成负数/巨值。
    @Test func tickWraparound() {
        // 单核 user tick 从 0xFFFFFF00 回绕到 0x000000FF → 增量 0x1FF = 511
        let previous: [UInt32] = [0xFFFF_FF00, 0, 0, 0]
        let current: [UInt32] = [0x0000_00FF, 0, 0, 0]
        let r = CPUUsageMath.compute(previous: previous, current: current, coreCount: 1)
        #expect(abs(r.perCore[0] - 1.0) < 1e-9)   // 全部是 busy
        #expect(abs(r.total - 1.0) < 1e-9)
        #expect(abs(r.idle - 0.0) < 1e-9)
        #expect(abs(r.user - 1.0) < 1e-9)
    }

    /// 回绕 + idle 同时增长：4 个 state 都跨越 2^32。
    @Test func tickWraparoundMixed() {
        let previous: [UInt32] = [0xFFFF_FFF0, 0xFFFF_FFF0, 0xFFFF_FF00, 0]
        let current: [UInt32] = [0x0000_0010, 0x0000_0010, 0x0000_0200, 0]
        let r = CPUUsageMath.compute(previous: previous, current: current, coreCount: 1)
        // user 增量 32, system 增量 32, idle 增量 0x300 = 768 → busy 64 / 832
        #expect(abs(r.perCore[0] - 64.0 / 832.0) < 1e-9)
        #expect(abs(r.total - 64.0 / 832.0) < 1e-9)
        #expect(r.total >= 0 && r.total <= 1)
    }

    /// 全 idle：总占用 0，idle 1，每核心 0。
    @Test func allIdle() {
        let previous: [UInt32] = [10, 5, 1000, 0, 20, 5, 2000, 0]
        let current: [UInt32] = [10, 5, 1500, 0, 20, 5, 2600, 0]
        let r = CPUUsageMath.compute(previous: previous, current: current, coreCount: 2)
        #expect(r.total == 0)
        #expect(r.user == 0)
        #expect(r.system == 0)
        #expect(r.idle == 1)
        #expect(r.perCore == [0, 0])
    }

    /// 满负载：idle 不增长，占用恒为 1。
    @Test func fullLoad() {
        let previous: [UInt32] = [0, 0, 0, 0, 0, 0, 0, 0]
        let current: [UInt32] = [500, 400, 0, 0, 100, 100, 0, 0]
        let r = CPUUsageMath.compute(previous: previous, current: current, coreCount: 2)
        #expect(r.total == 1)
        #expect(r.idle == 0)
        #expect(r.perCore == [1, 1])
    }

    /// nice 计入 user（UI 只有 user/system/idle 三段）。
    @Test func niceCountsAsUser() {
        let r = CPUUsageMath.compute(previous: [0, 0, 0, 0], current: [0, 0, 0, 100], coreCount: 1)
        #expect(r.user == 1)
        #expect(r.total == 1)
        #expect(r.idle == 0)
    }

    /// 核心数为 0：perCore 为空、不崩、不除零。
    @Test func zeroCoreCount() {
        let r = CPUUsageMath.compute(previous: [], current: [], coreCount: 0)
        #expect(r.perCore.isEmpty)
        #expect(r.total == 0)
        #expect(r.user == 0)
        #expect(r.system == 0)
        #expect(r.idle == 1)
    }

    /// 负的核心数（防御性）：同样按 0 处理。
    @Test func negativeCoreCount() {
        let r = CPUUsageMath.compute(previous: [1, 2, 3, 4], current: [2, 3, 4, 5], coreCount: -3)
        #expect(r.perCore.isEmpty)
        #expect(r.idle == 1)
    }

    /// 数组长度不足：perCore 仍然补齐到 coreCount（缺失核心为 0），不越界。
    @Test func shortArrays() {
        // 只有 1 个核心的数据，却要求 4 个核心
        let r = CPUUsageMath.compute(previous: [0, 0, 100, 0], current: [10, 10, 180, 0],
                                     coreCount: 4)
        #expect(r.perCore.count == 4)
        #expect(abs(r.perCore[0] - 20.0 / 100.0) < 1e-9)
        #expect(r.perCore[1] == 0)
        #expect(r.perCore[2] == 0)
        #expect(r.perCore[3] == 0)
    }

    /// 数组长度不是 4 的整数倍：多出来的尾巴被忽略，不越界。
    @Test func raggedArrayLength() {
        let r = CPUUsageMath.compute(previous: [0, 0, 0, 0, 7], current: [1, 1, 1, 1, 9],
                                     coreCount: 3)
        #expect(r.perCore.count == 3)
        #expect(r.perCore[1] == 0)
        #expect(r.perCore[2] == 0)
        #expect(r.total >= 0 && r.total <= 1)
    }

    /// 增量和为 0（两拍完全一样 / 空数组）：除零保护，值域仍然合法。
    @Test func zeroDelta() {
        let same: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 8]
        let r = CPUUsageMath.compute(previous: same, current: same, coreCount: 2)
        #expect(r.total == 0)
        #expect(r.user == 0)
        #expect(r.system == 0)
        #expect(r.idle == 1)
        #expect(r.perCore == [0, 0])

        let empty = CPUUsageMath.compute(previous: [], current: [], coreCount: 3)
        #expect(empty.perCore.count == 3)
        #expect(empty.idle == 1)
    }

    /// 值域与长度不变量：随机（含回绕）输入下必须满足 0...1 且 perCore.count == coreCount。
    @Test func invariantsUnderRandomInput() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        for _ in 0..<200 {
            let cores = Int.random(in: 0...17, using: &generator)
            var previous = [UInt32]()
            var current = [UInt32]()
            for _ in 0..<(cores * ticksPerCore) {
                let base = UInt32.random(in: 0...UInt32.max, using: &generator)
                previous.append(base)
                // 一半用普通增长，一半强制跨 2^32 回绕
                let delta = UInt32.random(in: 0...5000, using: &generator)
                current.append(generator.nextBool() ? base &+ delta : base &- delta)
            }
            let r = CPUUsageMath.compute(previous: previous, current: current, coreCount: cores)
            #expect(r.perCore.count == cores)
            #expect(r.total >= 0 && r.total <= 1)
            #expect(r.user >= 0 && r.user <= 1)
            #expect(r.system >= 0 && r.system <= 1)
            #expect(r.idle >= 0 && r.idle <= 1)
            for value in r.perCore {
                #expect(value >= 0 && value <= 1)
            }
        }
    }

    /// tickDelta 直接测回绕语义。
    @Test func tickDeltaWraps() {
        #expect(tickDelta(10, 20) == 10)
        #expect(tickDelta(20, 10) == (UInt64(UInt32.max) - 20 + 10 + 1))
        #expect(tickDelta(0, 0) == 0)
        #expect(tickDelta(UInt32.max, 0) == 1)
    }

    /// clamp01 的边界（NaN 归 0，超界夹取）。
    @Test func clampBehaviour() {
        #expect(clamp01(-1) == 0)
        #expect(clamp01(0) == 0)
        #expect(clamp01(0.5) == 0.5)
        #expect(clamp01(1) == 1)
        #expect(clamp01(2) == 1)
        #expect(clamp01(.nan) == 0)
        #expect(clamp01(.infinity) == 1)
    }
}

/// 可复现的伪随机数发生器（避免测试之间互相影响）。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }

    mutating func nextBool() -> Bool { next() & 1 == 0 }
}
