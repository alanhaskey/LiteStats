// 历史统计的契约测试：聚合语义、跨边界分桶、保留策略、清空、应用排序、
// nettop 解析（纯函数）、以及 nettop 缺失时的降级。
//
// 所有涉及磁盘的用例都用独立临时目录（swift-testing 默认并行跑 suite，
// 共用目录会互相踩），跑完删掉。
import Foundation
import Testing

@testable import LiteStatsCore

// MARK: - 测试脚手架

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("litestats-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// 构造一个"可控"的快照：只有 CPU / 内存 / GPU / 网络 / 温度参与历史统计。
private func makeSnapshot(at date: Date,
                          cpuTotal: Double = 0.5,
                          coreCount: Int = 4,
                          memoryUsed: UInt64 = 4_000_000_000,
                          gpuUtilization: Double? = 0.25,
                          download: Double = 1000,
                          upload: Double = 500,
                          cpuTemperature: Double? = 50) -> SystemSnapshot {
    let cpu = CPUStats(total: cpuTotal, user: cpuTotal, system: 0, idle: 1 - cpuTotal,
                       perCore: [Double](repeating: cpuTotal, count: coreCount),
                       coreCount: coreCount, load1: 1, load5: 1, load15: 1)
    let memory = MemoryStats(total: 16_000_000_000, used: memoryUsed, free: 0, active: 0,
                             inactive: 0, wired: 0, compressed: 0, cached: 0,
                             swapTotal: 0, swapUsed: 0)
    let gpu = GPUStats(name: "test", utilization: gpuUtilization,
                       inUseMemory: nil, allocatedMemory: nil)
    let network = NetworkStats(download: download, upload: upload, received: 0, sent: 0,
                              interfaceName: "en0", isConnected: true)
    let thermal = ThermalStats(cpuTemperature: cpuTemperature, gpuTemperature: nil,
                               batteryTemperature: nil, sensors: [], fans: [],
                               sourceDescription: cpuTemperature == nil ? nil : "test",
                               readMillis: 0)
    return SystemSnapshot(timestamp: date, cpu: cpu, memory: memory, gpu: gpu,
                          network: network, disk: nil, uptime: 100,
                          thermalState: .nominal, sampleIndex: 1, thermal: thermal)
}

/// 本地日历里的一个确定时刻（用 Calendar.current 造，避免测试自己引入时区错误）。
private func localDate(year: Int, month: Int, day: Int,
                       hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

/// 相对"现在"的一个整分钟（保留秒数，用来精确控制落在哪一分钟里）。
private func minutesAgo(_ minutes: Double, now: Date = Date()) -> Date {
    Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60 - minutes * 60)
}

// MARK: - 分钟聚合

@Suite("历史：分钟聚合")
struct HistoryMinuteAggregationTests {

    @Test func sameHourAccumulatesIntoSingleBucket() throws {
        // 分钟明细已停写：同一小时的多拍现在直接合并成一个小时桶
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)

        let base = localDate(year: 2025, month: 6, day: 10, hour: 13, minute: 20, second: 0)
        // 同一小时内 4 拍，每拍 1 秒、CPU 50%、4 核 → 每拍 2 CPU 秒
        for offset in 0..<4 {
            store.record(snapshot: makeSnapshot(at: base.addingTimeInterval(Double(offset)),
                                                cpuTotal: 0.5, coreCount: 4,
                                                download: 1000, upload: 500),
                         interval: 1)
        }

        let summary = store.summary(from: base.addingTimeInterval(-60),
                                    to: base.addingTimeInterval(120))
        #expect(summary.hourly.count == 1, "同一小时必须只有一个桶")
        let bucket = try #require(summary.hourly.first)
        #expect(bucket.hourStart == localDate(year: 2025, month: 6, day: 10, hour: 13))
        #expect(bucket.sampleCount == 4)
        // 4 拍 × (0.5 × 1s × 4 核) = 8 CPU 秒
        #expect(abs(bucket.cpuSeconds - 8) < 1e-9)
        #expect(abs(summary.cpuSeconds - 8) < 1e-9)
        #expect(abs(bucket.gpuPercentAverage - 0.25) < 1e-9)
    }

    @Test func unknownGPUDegradesToZeroInsteadOfPollutingAverage() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)
        let base = localDate(year: 2025, month: 6, day: 10, hour: 15, minute: 0, second: 0)
        store.record(snapshot: makeSnapshot(at: base, gpuUtilization: nil), interval: 1)
        let summary = store.summary(from: base, to: base.addingTimeInterval(60))
        #expect(summary.hourly.first?.gpuPercentAverage == 0)
    }
}

// MARK: - 跨分钟 / 小时 / 天边界

@Suite("历史：时间边界分桶")
struct HistoryBoundaryTests {

    @Test func crossingMinuteAndHourCreatesSeparateBuckets() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)

        // 13:59:30 与 14:00:30：跨分钟，也跨小时
        let first = localDate(year: 2025, month: 6, day: 10, hour: 13, minute: 59, second: 30)
        let second = localDate(year: 2025, month: 6, day: 10, hour: 14, minute: 0, second: 30)
        store.record(snapshot: makeSnapshot(at: first), interval: 1)
        store.record(snapshot: makeSnapshot(at: second), interval: 1)

        let summary = store.summary(from: localDate(year: 2025, month: 6, day: 10, hour: 13),
                                    to: localDate(year: 2025, month: 6, day: 10, hour: 15))
        #expect(summary.hourly.count == 2, "13 点和 14 点各一个桶")
        #expect(summary.hourly[0].hourStart == localDate(year: 2025, month: 6, day: 10, hour: 13))
        #expect(summary.hourly[1].hourStart == localDate(year: 2025, month: 6, day: 10, hour: 14))
        #expect(summary.hourly[0].sampleCount == 1)
        #expect(summary.hourly[1].sampleCount == 1)

        // 只查 14 点：13 点那拍不能算进来
        let onlySecondHour = store.summary(from: localDate(year: 2025, month: 6, day: 10, hour: 14),
                                           to: localDate(year: 2025, month: 6, day: 10, hour: 15))
        #expect(onlySecondHour.hourly.count == 1)
        #expect(abs(onlySecondHour.trackDuration - 1) < 1e-9)
    }

    @Test func crossingDayBoundarySplitsTodayAndYesterday() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)

        let yesterdayLate = localDate(year: 2025, month: 6, day: 9, hour: 23, minute: 59, second: 40)
        let todayEarly = localDate(year: 2025, month: 6, day: 10, hour: 0, minute: 0, second: 20)
        store.record(snapshot: makeSnapshot(at: yesterdayLate, download: 100, upload: 0), interval: 1)
        store.record(snapshot: makeSnapshot(at: todayEarly, download: 200, upload: 0), interval: 1)

        let today = store.today(now: todayEarly.addingTimeInterval(30))
        #expect(today.rangeStart == localDate(year: 2025, month: 6, day: 10))
        #expect(today.networkIn == 200, "today() 不能把昨天 23:59 的流量算进来")
        #expect(today.hourly.count == 1)
        #expect(today.hourly.first?.hourStart == localDate(year: 2025, month: 6, day: 10, hour: 0))

        let yesterday = store.summary(from: localDate(year: 2025, month: 6, day: 9),
                                      to: localDate(year: 2025, month: 6, day: 10))
        #expect(yesterday.networkIn == 100)
    }

    @Test func rolloverThroughSixHoursSealsBuckets() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)

        // 从 10:59:30 跳到 16:00:30：中间 5 小时没采样（程序没跑）
        let before = localDate(year: 2025, month: 6, day: 11, hour: 10, minute: 59, second: 30)
        let after = localDate(year: 2025, month: 6, day: 11, hour: 16, minute: 0, second: 30)
        store.record(snapshot: makeSnapshot(at: before, download: 60, upload: 0), interval: 1)
        store.record(snapshot: makeSnapshot(at: after, download: 120, upload: 0), interval: 1)

        // 跳变前的小时 / 天都必须已经封口，不能被后来的数据污染。
        let firstHour = store.summary(from: localDate(year: 2025, month: 6, day: 11, hour: 10),
                                      to: localDate(year: 2025, month: 6, day: 11, hour: 11))
        #expect(firstHour.networkIn == 60)
        #expect(abs(firstHour.trackDuration - 1) < 1e-9, "没采样的 5 小时不能被算成记录时长")
    }
}

// MARK: - 区间查询

@Suite("历史：区间查询")
struct HistoryRangeQueryTests {

    /// 用**固定的锚点时间**造数据，避免"测试刚好跑在整点 / 跨天附近"造成的抖动：
    /// 数据写在 2025-06-10 的 10:00 / 11:00 / 12:00，查询时显式把 now 传成 12:30。
    /// （record 用的是 snapshot.timestamp，所以数据时间完全可控；today()/lastHours() 都接受 now 参数。）
    private static let anchor = localDate(year: 2025, month: 6, day: 10, hour: 12, minute: 30)

    private func makeStoreWithHourlyData() throws -> (HistoryStore, URL) {
        let directory = try makeTemporaryDirectory()
        let store = try HistoryStore(directory: directory)
        // 按时间先后写：10 点、11 点会被封口成小时记录，12 点是"当前小时"（还在内存累加器里）
        for hour in [10, 11, 12] {
            for tick in 0..<2 {
                let date = localDate(year: 2025, month: 6, day: 10, hour: hour,
                                     minute: 0, second: tick)
                store.record(snapshot: makeSnapshot(at: date, download: 100, upload: 10), interval: 1)
            }
        }
        return (store, directory)
    }

    @Test func lastHoursCoversRollingWindow() throws {
        let (store, directory) = try makeStoreWithHourlyData()
        defer { removeDirectory(directory) }

        let one = store.lastHours(1, now: Self.anchor)
        // 11:30 → 12:30：按**整小时粒度**计入（分钟明细已停写，做不了更细的边界折算）：
        // 11 点整桶（2 拍）+ 当前未封口的 12 点（2 拍）
        #expect(one.networkIn == 400, "小时粒度：11 点与 12 点各 200")
        #expect(one.networkOut == 40)
        #expect(abs(one.trackDuration - 4) < 1e-9)

        let three = store.lastHours(3, now: Self.anchor)
        #expect(three.networkIn == 600, "3 小时窗口要覆盖 10/11/12 三个小时")
        #expect(three.hourly.count == 3)
        #expect(three.hourly.map(\.hourStart) == [10, 11, 12].map {
            localDate(year: 2025, month: 6, day: 10, hour: $0)
        })
    }

    @Test func lastDaysOneEqualsToday() throws {
        let (store, directory) = try makeStoreWithHourlyData()
        defer { removeDirectory(directory) }

        let days = store.lastDays(1, now: Self.anchor)
        let today = store.today(now: Self.anchor)
        #expect(days.rangeStart == localDate(year: 2025, month: 6, day: 10))
        #expect(days.rangeStart == today.rangeStart)
        #expect(days.networkIn == today.networkIn)
        #expect(days.networkIn == 600)

        // 昨天什么都没有
        let yesterday = store.summary(from: localDate(year: 2025, month: 6, day: 9),
                                      to: localDate(year: 2025, month: 6, day: 10))
        #expect(yesterday.networkTotal == 0)
        #expect(yesterday.hourly.isEmpty)
    }

    @Test func customRangeAndInvalidRange() throws {
        let (store, directory) = try makeStoreWithHourlyData()
        defer { removeDirectory(directory) }

        let custom = store.summary(from: Self.anchor.addingTimeInterval(-3 * 3600), to: Self.anchor)
        #expect(custom.networkIn == 600)
        #expect(custom.hourly.count == 3)

        // 只覆盖 10 点那一小时
        let firstHourOnly = store.summary(from: localDate(year: 2025, month: 6, day: 10, hour: 10),
                                          to: localDate(year: 2025, month: 6, day: 10, hour: 11))
        #expect(firstHourOnly.networkIn == 200)
        #expect(firstHourOnly.hourly.count == 1)

        // from >= to 必须是空汇总，不能崩、不能返回负数
        let now = Self.anchor
        let empty = store.summary(from: now, to: now.addingTimeInterval(-10))
        #expect(empty.networkTotal == 0)
        #expect(empty.hourly.isEmpty)
        #expect(empty.apps.isEmpty)
        #expect(empty.trackDuration == 0)
        #expect(empty.averageCPUUsage(coreCount: 8) == 0)
    }

    @Test func averageCPUUsageUsesCoreCount() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)
        let minuteStart = localDate(year: 2025, month: 6, day: 10, hour: 9, minute: 15, second: 0)
        // 4 核、CPU 50%、一拍 1 秒 → 2 CPU 秒 / (1 秒 × 4 核) = 0.5
        store.record(snapshot: makeSnapshot(at: minuteStart, cpuTotal: 0.5, coreCount: 4), interval: 1)
        let summary = store.summary(from: minuteStart.addingTimeInterval(-60),
                                    to: minuteStart.addingTimeInterval(60))
        #expect(abs(summary.cpuSeconds - 2) < 1e-9)
        #expect(abs(summary.averageCPUUsage(coreCount: 4) - 0.5) < 1e-9)
        #expect(summary.averageCPUUsage(coreCount: 0) == 0)
    }
}

// MARK: - 保留策略

@Suite("历史：保留策略")
struct HistoryRetentionTests {

    @Test func staleHourBucketsArePruned() throws {
        // 分钟明细已停写，改成验证小时桶的保留期（180 天）
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)

        let old = minutesAgo(60 * 24 * 200)          // 200 天前：超过 180 天保留期
        store.record(snapshot: makeSnapshot(at: old), interval: 1)
        store.flush()
        #expect(store.debugRecordCounts.hours == 1, "先正常写进去")

        let fresh = Date()
        store.record(snapshot: makeSnapshot(at: fresh), interval: 1)
        store.pruneForTesting(now: fresh)
        #expect(store.debugRecordCounts.hours == 0, "跨天清理后 200 天前的小时桶消失")
        #expect(store.debugRecordCounts.days == 1, "天级桶永久保留，不受清理影响")
    }

    @Test func hourDetailOlderThan180DaysIsPruned() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let now = Date()
        let ancient = now.addingTimeInterval(-181 * 86400)
        let ancientDayStart = Calendar.current.dateInterval(of: .day, for: ancient)?.start ?? ancient
        let dayEnd = ancientDayStart.addingTimeInterval(86400)

        do {
            let store = try HistoryStore(directory: directory)
            store.record(snapshot: makeSnapshot(at: ancient, download: 5000, upload: 0), interval: 1)
            store.flush()
        }

        let reopened = try HistoryStore(directory: directory)
        reopened.flush()
        let counts = reopened.debugRecordCounts
        #expect(counts.hours == 0, "181 天前的小时明细必须被清掉")
        #expect(counts.minutes == 0)

        // 小时明细没了 → hourly 里不再有这个桶（"180 天前的小时数据清理后不再返回"）
        let summary = reopened.summary(from: ancientDayStart, to: dayEnd)
        #expect(summary.hourly.isEmpty, "180 天前的小时数据清理后不再返回小时桶")

        // 天级是永久保留的，所以"去年今天用了多少流量"仍然答得出来。
        #expect(summary.networkIn == 5000, "天级汇总永久保留，180 天以前的区间仍应给出总量")
        #expect(reopened.debugRecordCounts.days >= 1)
    }

    @Test func pruneForTestingDropsStaleLayersImmediately() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)
        let now = Date()
        store.record(snapshot: makeSnapshot(at: now.addingTimeInterval(-200 * 86400)), interval: 1)
        store.record(snapshot: makeSnapshot(at: now), interval: 1)
        store.flush()

        store.pruneForTesting(now: now)
        let counts = store.debugRecordCounts
        #expect(counts.hours == 1, "180 天前的小时桶被清理")
        #expect(counts.days == 2, "天级永久保留")
    }
}

// MARK: - 清空

@Suite("历史：清空")
struct HistoryResetTests {

    @Test func resetAllClearsFilesAndMemory() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)
        let now = Date()

        for tick in 0..<5 {
            store.record(snapshot: makeSnapshot(at: now.addingTimeInterval(Double(tick)), download: 1000, upload: 1000),
                         interval: 1)
        }
        store.record(appSamples: [AppUsageSample(name: "Xcode", path: "/Applications/Xcode.app/Xcode",
                                                 cpuSeconds: 3, memoryBytes: 900_000_000,
                                                 networkIn: 4096, networkOut: 1024)],
                     interval: 1)
        store.flush()
        #expect(store.storageBytes > 0)
        #expect(store.today(now: now).networkTotal > 0)

        try store.resetAll()

        #expect(store.storageBytes == 0, "resetAll 之后磁盘占用必须归零")
        let summary = store.today(now: now)
        #expect(summary.networkTotal == 0)
        #expect(summary.cpuSeconds == 0)
        #expect(summary.gpuSeconds == 0)
        #expect(summary.memoryBytesAverage == 0)
        #expect(summary.trackDuration == 0)
        #expect(summary.hourly.isEmpty)
        #expect(summary.apps.isEmpty)
        #expect(store.minuteSamples(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(60)).isEmpty)
        #expect(store.debugRecordCounts.minutes == 0)

        // 清空之后还能继续正常记录（不能把 store 用坏）
        store.record(snapshot: makeSnapshot(at: now.addingTimeInterval(60), download: 500, upload: 0), interval: 1)
        #expect(store.today(now: now.addingTimeInterval(61)).networkIn == 500)
        store.flush()
        #expect(store.storageBytes > 0)
    }

    @Test func persistenceRoundTripSurvivesReopen() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let now = Date()
        let minuteStart = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)

        do {
            let store = try HistoryStore(directory: directory)
            store.record(snapshot: makeSnapshot(at: minuteStart, cpuTotal: 1, coreCount: 2,
                                                download: 1234, upload: 567),
                         interval: 1)
            store.record(appSamples: [
                AppUsageSample(name: "swift-frontend", path: "/usr/bin/swift-frontend",
                               cpuSeconds: 2.5, memoryBytes: 700_000_000,
                               networkIn: 0, networkOut: 0),
                AppUsageSample(name: "Safari", path: "/Applications/Safari.app/Safari",
                               cpuSeconds: 0.1, memoryBytes: 500_000_000,
                               networkIn: 50_000_000, networkOut: 1_000_000),
            ], interval: 2)
            store.flush()
        }

        let reopened = try HistoryStore(directory: directory)
        let summary = reopened.today(now: now.addingTimeInterval(1))
        #expect(summary.networkIn == 1234)
        #expect(summary.networkOut == 567)
        #expect(abs(summary.cpuSeconds - 2) < 1e-9)
        #expect(summary.apps.count == 2)
        // 权重：swift-frontend = 2.5 CPU 秒 × 1e8 = 2.5e8 > Safari 的 5.1e7
        #expect(summary.apps.first?.name == "swift-frontend")
        #expect(summary.apps.first?.cpuSeconds == 2.5)
        // name→path 旁表已弃用（界面只用应用名）：path 恒为 nil
        #expect(summary.apps.first?.path == nil)
        #expect(summary.apps.last?.name == "Safari")
        #expect(summary.apps.last?.networkIn == 50_000_000)
    }
}

// MARK: - 应用增量与排序

@Suite("历史：应用聚合与排序")
struct HistoryAppUsageTests {

    @Test func appSamplesAggregateAndSortByImpact() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)

        // 三轮采样：验证 cpuSeconds 累加、peakMemoryBytes 取峰值、网络累加
        for round in 0..<3 {
            store.record(appSamples: [
                // 纯计算型：3 轮 × 1 CPU 秒 = 3 秒 → 权重 3e8
                AppUsageSample(name: "swift-frontend", path: "/usr/bin/swift-frontend",
                               cpuSeconds: 1, memoryBytes: UInt64(100_000_000 * (round + 1)),
                               networkIn: 0, networkOut: 0),
                // 纯下载型：3 轮 × 20 MB = 60 MB → 权重 6e7，最低
                AppUsageSample(name: "Safari", path: "/Applications/Safari.app/Safari",
                               cpuSeconds: 0, memoryBytes: 500_000_000,
                               networkIn: 20_000_000, networkOut: 0),
                // 纯上传型：3 轮 × 120 MB = 360 MB → 权重 3.6e8，最高
                AppUsageSample(name: "Backup", path: nil,
                               cpuSeconds: 0, memoryBytes: 10_000_000,
                               networkIn: 0, networkOut: 120_000_000),
                // 微不足道：应该被过滤掉（不占磁盘、不出现在结果里）
                AppUsageSample(name: "idle-daemon", path: nil,
                               cpuSeconds: 0, memoryBytes: 1_000_000,
                               networkIn: 0, networkOut: 0),
            ], interval: 2)
        }

        let summary = store.today()
        let names = summary.apps.map(\.name)
        #expect(names == ["Backup", "swift-frontend", "Safari"],
                "排序应为 网络总字节 + CPU 秒 × 1e8 降序，实际：\(names)")
        #expect(!names.contains("idle-daemon"), "无 CPU、无网络、内存很小的进程不该留档")

        let frontend = try #require(summary.apps.first { $0.name == "swift-frontend" })
        #expect(abs(frontend.cpuSeconds - 3) < 1e-9)
        #expect(frontend.peakMemoryBytes == 300_000_000, "peakMemoryBytes 必须是峰值而不是最后一拍")
        #expect(frontend.sampleCount == 3)

        let safari = try #require(summary.apps.first { $0.name == "Safari" })
        #expect(safari.networkIn == 60_000_000)
        #expect(safari.cpuSeconds == 0)
    }

    @Test func impactWeightFormulaIsDocumented() {
        // 1 秒 CPU 折算 1e8 字节（100MB）
        #expect(HistoryRanking.bytesPerCPUSecond == 1e8)
        #expect(HistoryRanking.impactWeight(networkIn: 0, networkOut: 0, cpuSeconds: 1) == 1e8)
        #expect(HistoryRanking.impactWeight(networkIn: 50, networkOut: 50, cpuSeconds: 0) == 100)
        #expect(HistoryRanking.impactWeight(networkIn: 100, networkOut: 0, cpuSeconds: 1) == 100 + 1e8)
    }

    @Test func appRangeFilteringDropsOutOfRangeBuckets() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)
        store.record(appSamples: [AppUsageSample(name: "Now", path: nil, cpuSeconds: 10,
                                                 memoryBytes: 0, networkIn: 0, networkOut: 0)],
                     interval: 1)
        let past = store.summary(from: Date().addingTimeInterval(-10 * 86400),
                                 to: Date().addingTimeInterval(-9 * 86400))
        #expect(past.apps.isEmpty, "10 天前的区间不该出现今天才采到的应用")
    }
}

// MARK: - nettop 解析（纯函数）

@Suite("历史：nettop 解析")
struct NettopParserTests {

    /// 真实 nettop 输出（`-P -x -l 1 -J bytes_in,bytes_out -n`）的片段，
    /// 特意混进各种形态：带空格、带括号、带点、纯数字名字、前导空格、表头。
    private let sampleOutput = """
                                                                        bytes_in       bytes_out
    kernel_task.0                                                            8504            6316
    launchd.1                                                                   0               0
    OrbStack Helper.1336                                                  3258443          544716
    WeChatAppEx Hel.7914                                                     6137            4953
    com.apple.WebKit.WebContent.4242                                      1048576               0
    Google Chrome Helper (Renderer).9182                                 20480000         1024000
    2.3456                                                                     12              34
    Lingma.4652                                                          17023361          762902
    mDNSResponder.684                                                    80237303        68299719
    reportd.1234
    
    some line without numbers
    """

    @Test func parsesRealNettopOutput() {
        let entries = NettopParser.parse(sampleOutput)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        #expect(entries.count == 9, "表头 / 空行 / 纯文本行都必须被跳过，实际解析出 \(entries.count) 条")

        // kernel_task 的 PID 是 0，不能被当成非法行
        #expect(byName["kernel_task"]?.pid == 0)
        #expect(byName["kernel_task"]?.bytesIn == 8504)

        let mdns = byName["mDNSResponder"]
        #expect(mdns?.pid == 684)
        #expect(mdns?.bytesIn == 80_237_303)
        #expect(mdns?.bytesOut == 68_299_719)

        // 名字里带空格
        #expect(byName["OrbStack Helper"]?.pid == 1336)
        #expect(byName["OrbStack Helper"]?.bytesIn == 3_258_443)
        // 名字里带空格 + 大小写混合
        #expect(byName["WeChatAppEx Hel"]?.pid == 7914)
        #expect(byName["WeChatAppEx Hel"]?.bytesOut == 4953)
        // 名字里带点（PID 取最后一个点之后的）
        #expect(byName["com.apple.WebKit.WebContent"]?.pid == 4242)
        #expect(byName["com.apple.WebKit.WebContent"]?.bytesIn == 1_048_576)
        // 名字里带括号 + 空格 + 点
        #expect(byName["Google Chrome Helper (Renderer)"]?.pid == 9182)
        #expect(byName["Google Chrome Helper (Renderer)"]?.bytesOut == 1_024_000)
        // 纯数字进程名
        #expect(byName["2"]?.pid == 3456)
        #expect(byName["2"]?.bytesIn == 12)
        // 缩进很深的普通行
        #expect(byName["Lingma"]?.bytesIn == 17_023_361)
    }

    @Test func skipsHeaderAndGarbage() {
        #expect(NettopParser.parseLine("                                    bytes_in       bytes_out") == nil)
        #expect(NettopParser.parseLine("") == nil)
        #expect(NettopParser.parseLine("some line without numbers") == nil)
        #expect(NettopParser.parseLine("only_two tokens.12 345") == nil)
        // PID 不是数字 → 丢掉整行（宁可少算，也不要把名字当 PID）
        #expect(NettopParser.parseLine("weird.name.notapid  100  200") == nil)
        // 负数 / 非十进制数字 → 丢掉
        #expect(NettopParser.parseLine("proc.12  -1  200") == nil)
    }

    @Test func pidIsTakenAfterLastDotOnly() {
        let entry = NettopParser.parseLine("a.b.c.99\t1000\t2000")
        #expect(entry?.name == "a.b.c")
        #expect(entry?.pid == 99)
        #expect(entry?.bytesIn == 1000)
        #expect(entry?.bytesOut == 2000)
    }

    @Test func diffUsesFullProcessNameFromLibproc() {
        // nettop 把 "DSH Desktop Helper" 截断成 "DSH Desktop Hel"；
        // 同一拍 libproc 给出完整名字，差分结果必须归到完整名字上，
        // 否则同一个应用会被拆成"有 CPU 的"和"有网络的"两条。
        let previous = ["684|mDNSResponder": (bytesIn: UInt64(1000), bytesOut: UInt64(500)),
                        "42|DSH Desktop Hel": (bytesIn: UInt64(10), bytesOut: UInt64(20))]
        let current = [NettopProcessCounters(name: "mDNSResponder", pid: 684,
                                             bytesIn: 1500, bytesOut: 900),
                       NettopProcessCounters(name: "DSH Desktop Hel", pid: 42,
                                             bytesIn: 110, bytesOut: 220)]
        let result = AppUsageCollector.diffNettop(previous: previous, current: current,
                                                  namesByPid: [684: "mDNSResponder",
                                                               42: "DSH Desktop Helper"])
        #expect(result.deltas["mDNSResponder"]?.in == 500)
        #expect(result.deltas["mDNSResponder"]?.out == 400)
        #expect(result.deltas["DSH Desktop Helper"]?.in == 100)
        #expect(result.deltas["DSH Desktop Helper"]?.out == 200)
        #expect(result.deltas["DSH Desktop Hel"] == nil, "截断名字不该再出现")
        #expect(result.baseline["42|DSH Desktop Hel"]?.bytesIn == 110)
    }

    @Test func diffHandlesPidReuseAndCounterReset() {
        // pid 被复用（名字变了）→ key 不同 → 本次只建基线，不产生增量
        let previous = ["42|OldApp": (bytesIn: UInt64(999_999), bytesOut: UInt64(999_999))]
        let reused = [NettopProcessCounters(name: "NewApp", pid: 42, bytesIn: 10, bytesOut: 20)]
        let reuseResult = AppUsageCollector.diffNettop(previous: previous, current: reused,
                                                       namesByPid: [42: "NewApp"])
        #expect(reuseResult.deltas.isEmpty)
        #expect(reuseResult.baseline["42|NewApp"]?.bytesIn == 10)

        // 计数器回绕 / 进程重启（数值变小）→ 负增量按 0 处理，不产生巨大的假增量
        let resetResult = AppUsageCollector.diffNettop(previous: ["42|NewApp": (bytesIn: UInt64(10), bytesOut: UInt64(20))],
                                                       current: [NettopProcessCounters(name: "NewApp", pid: 42,
                                                                                       bytesIn: 1, bytesOut: 2)],
                                                       namesByPid: [42: "NewApp"])
        #expect(resetResult.deltas.isEmpty)
    }

    @Test func diffKeepsSilentProcessesOutOfDeltas() {
        let previous = ["9|idle": (bytesIn: UInt64(5), bytesOut: UInt64(5))]
        let current = [NettopProcessCounters(name: "idle", pid: 9, bytesIn: 5, bytesOut: 5)]
        let result = AppUsageCollector.diffNettop(previous: previous, current: current,
                                                  namesByPid: [9: "idle"])
        #expect(result.deltas.isEmpty, "数值没变就不该产生 0 增量的条目")
        #expect(result.baseline.count == 1)
    }
}

// MARK: - 降级

@Suite("历史：采集器降级")
struct AppUsageCollectorDegradationTests {

    @Test func firstSampleIsBaselineAndReturnsEmpty() {
        let collector = AppUsageCollector(nettopPath: "/nonexistent/nettop")
        #expect(collector.sample().isEmpty, "第一次采样只建立基线")
        #expect(collector.sample().isEmpty == false, "第二次采样应该能给出进程列表")
    }

    @Test func missingNettopOnlyLosesNetwork() throws {
        let collector = AppUsageCollector(nettopPath: "/nonexistent/nettop", nettopEveryNSamples: 1)
        _ = collector.sample()                       // 建基线
        let samples = collector.sample()
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.networkIn == 0 && $0.networkOut == 0 },
                "nettop 不存在时必须降级成只有 CPU / 内存（网络为 0），而不是抛错")
        #expect(samples.contains { $0.memoryBytes > 0 }, "内存仍然应该采到")
        #expect(samples.allSatisfy { $0.cpuSeconds >= 0 })
        #expect(collector.debugNettopRuns == 0, "路径不存在时不应有成功的 nettop 运行")
    }

    @Test func collectorDegradesWhenNettopIsNotExecutable() {
        // 指向一个真实存在但不可执行的路径（目录）
        let collector = AppUsageCollector(nettopPath: "/usr/bin", nettopEveryNSamples: 1)
        _ = collector.sample()
        let samples = collector.sample()
        #expect(!samples.isEmpty)
        #expect(samples.allSatisfy { $0.networkIn == 0 && $0.networkOut == 0 })
    }

    @Test func resetMakesNextSampleBaselineAgain() {
        let collector = AppUsageCollector(nettopPath: "/nonexistent/nettop")
        _ = collector.sample()
        _ = collector.sample()
        collector.reset()
        #expect(collector.sample().isEmpty, "reset 之后下一次采样重新当基线")
    }

    @Test func zeroNettopIntervalDoesNotCrash() {
        // nettopEveryNSamples = 0 会被夹成 1，不能触发取模除零
        let collector = AppUsageCollector(nettopPath: "/nonexistent/nettop", nettopEveryNSamples: 0)
        _ = collector.sample()
        _ = collector.sample()
        _ = collector.sample()
    }

    @Test func realNettopProducesProcessList() throws {
        // 集成冒烟：真跑一次 nettop（本机一定有 /usr/bin/nettop）。
        // 只断言"能解析出进程"，不断言流量数值（空闲机器上可能就是 0）。
        try #require(FileManager.default.isExecutableFile(atPath: NettopSampler.defaultExecutable))
        let entries = NettopSampler.sample()
        #expect(!entries.isEmpty, "真实 nettop 应该至少解析出若干进程")
        #expect(entries.allSatisfy { $0.pid >= 0 && !$0.name.isEmpty })
    }
}

// MARK: - 存储自检

@Suite("历史：存储格式")
struct HistoryStorageTests {

    @Test func recordStructSizesAreStable() {
        // 磁盘格式依赖这些常量；改了结构就必须升版本号，否则旧文件会被当损坏文件改名。
        #expect(MinuteRecord.byteCount == 72)
        #expect(BucketRecord.byteCount == 64)
        #expect(AppBucketRecord.byteCount == 128)
        #expect(MinuteRecord().encoded().count == MinuteRecord.byteCount)
        #expect(BucketRecord().encoded().count == BucketRecord.byteCount)
        #expect(AppBucketRecord().encoded().count == AppBucketRecord.byteCount)
    }

    @Test func longUnicodeNameIsTruncatedAtCharacterBoundary() {
        // 40 个三字节汉字 = 120 字节 > 72 字节容量，必须按字符边界截断（不能出现 U+FFFD）
        let name = String(repeating: "测", count: 40)
        let bytes = AppBucketRecord.truncatedNameBytes(name)
        #expect(bytes.count == AppBucketRecord.nameCapacity)
        var record = AppBucketRecord()
        record.nameBytes = bytes
        #expect(!record.name.isEmpty)
        #expect(!record.name.contains("\u{FFFD}"), "截断不能把多字节 UTF-8 字符劈开")
        #expect(record.name.allSatisfy { $0 == "测" })
    }

    @Test func corruptedFileIsQuarantinedInsteadOfCrashing() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        // 先写一个正常文件，再把头部魔数改坏，模拟"格式变了 / 文件被破坏"
        let store = try HistoryStore(directory: directory)
        store.record(snapshot: makeSnapshot(at: Date()), interval: 1)
        store.flush()
        let hoursURL = directory.appendingPathComponent("History/hours.bin")
        #expect(FileManager.default.fileExists(atPath: hoursURL.path))
        var data = try Data(contentsOf: hoursURL)
        data.replaceSubrange(0..<4, with: Data("XXXX".utf8))
        try data.write(to: hoursURL)

        let reopened = try HistoryStore(directory: directory)
        #expect(reopened.debugRecordCounts.hours == 0)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("History").path)
        #expect(entries.contains { $0.contains("corrupt") }, "坏文件应该被改名留档，而不是直接删掉")
    }

    @Test func truncatedTailRecordIsIgnored() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = try HistoryStore(directory: directory)
        let now = Date()
        store.record(snapshot: makeSnapshot(at: now, download: 100, upload: 0), interval: 1)
        store.flush()

        // 追加半条记录 = 模拟"写一半断电"
        let hoursURL = directory.appendingPathComponent("History/hours.bin")
        let handle = try FileHandle(forWritingTo: hoursURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0xAB, count: BucketRecord.byteCount / 2))
        try handle.close()

        let reopened = try HistoryStore(directory: directory)
        #expect(reopened.debugRecordCounts.hours == 1, "残缺尾巴必须被忽略，不能算成一条记录")
        #expect(reopened.today(now: now.addingTimeInterval(1)).networkIn == 100)
    }
}
