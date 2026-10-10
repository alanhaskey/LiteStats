// ⚠️ 占位测试（由 core-agent 扩写）
import Testing
@testable import LiteStatsCore

@Test func packageBuilds() {
    #expect(SystemMonitor().coreCount > 0)
}
