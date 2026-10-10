// NetworkRateMath 纯函数单测：正常换算、interval <= 0、计数器重置（current < previous）。
import Testing
@testable import LiteStatsCore

@Suite("NetworkRateMath")
struct NetworkRateMathTests {
    @Test func normalRate() {
        #expect(NetworkRateMath.bytesPerSecond(previous: 1000, current: 3000, interval: 2) == 1000)
        #expect(NetworkRateMath.bytesPerSecond(previous: 0, current: 1_000_000, interval: 0.5)
                == 2_000_000)
    }

    @Test func zeroIntervalDoesNotDivide() {
        #expect(NetworkRateMath.bytesPerSecond(previous: 0, current: 1000, interval: 0) == 0)
        #expect(NetworkRateMath.bytesPerSecond(previous: 0, current: 1000, interval: -1) == 0)
    }

    @Test func counterResetReturnsZero() {
        // 接口重连 / 32 位计数器回绕：绝不允许出现负数或天文数字
        #expect(NetworkRateMath.bytesPerSecond(previous: 5000, current: 10, interval: 1) == 0)
    }

    @Test func unchangedCounter() {
        #expect(NetworkRateMath.bytesPerSecond(previous: 42, current: 42, interval: 1) == 0)
    }

    @Test func hugeCounters() {
        // 64 位累计值不会溢出（用 Double 换算）
        let rate = NetworkRateMath.bytesPerSecond(previous: 0,
                                                  current: UInt64.max / 2,
                                                  interval: 1)
        #expect(rate > 0)
        #expect(rate.isFinite)
    }

    @Test func tinyInterval() {
        let rate = NetworkRateMath.bytesPerSecond(previous: 0, current: 1500, interval: 0.001)
        #expect(abs(rate - 1_500_000) < 1e-6)
    }
}
