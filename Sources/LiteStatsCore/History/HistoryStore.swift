// 历史统计的存储与聚合核心。
//
// 设计要点（为什么这么写）：
//
// 1. **内存是查询的唯一真相，磁盘只是持久化日志。**
//    历史数据总量很小（分钟级 7 天 ≈ 1 万条、小时级 180 天 ≈ 4 千条），
//    全部放内存后 `summary()` 不需要碰磁盘，几十微秒就能算完；
//    而 `record()` 是主线程每秒调用的热路径，只做内存累加 + 把"封口"的记录丢进
//    后台串行队列，实测 < 10 µs。
//
// 2. **按 分钟 → 小时 → 天 三级滚动。**
//    写一拍时同时累加到当前分钟、当前小时、当前天三个累加器里（不是封口时再折算），
//    这样"封口"只是把累加器序列化成一条记录，没有顺序依赖，也不会漏数据。
//
// 3. **只追加 + 断电安全。**
//    定长记录顺序追加，崩溃最多留一条残缺尾巴（读的时候按长度取整丢弃）；
//    只有"清理过期数据"才整体重写文件，走 `Data.write(options: .atomic)`（临时文件 + rename），
//    不存在"写一半把库写坏"的窗口。
//
// 4. **时间用 Calendar.current。**
//    用户看的"今天 / 本月"是本地日历概念，必须走 Calendar 而不是 `timeIntervalSince1970 / 86400`，
//    否则夏令时切换那天会整体错一小时。
import Foundation

/// 历史统计存储。线程安全（内部 NSLock），`record` 可以在主线程随便调。
public final class HistoryStore: @unchecked Sendable {

    // MARK: - 保留策略

    /// 分钟级明细保留 7 天。
    public static let minuteRetentionDays = 7
    /// 小时级汇总保留 180 天。
    public static let hourRetentionDays = 180
    /// 按应用的小时明细保留 7 天（和分钟级同一档：够回答"今天哪个时段是谁在跑"）。
    public static let appHourRetentionDays = 7
    /// 按应用的天级汇总保留 180 天（够回答"这个月谁用了多少流量"）。
    public static let appDayRetentionDays = 180
    /// 天级汇总永久保留（一年 365 行 × 64 字节 ≈ 23 KB，没必要清）。

    private static let minuteRetention: TimeInterval = Double(minuteRetentionDays) * 86400
    private static let hourRetention: TimeInterval = Double(hourRetentionDays) * 86400
    private static let appHourRetention: TimeInterval = Double(appHourRetentionDays) * 86400
    private static let appDayRetention: TimeInterval = Double(appDayRetentionDays) * 86400

    /// 单次 record 接受的 interval 上限：防止调用方传进来一个荒唐值把桶撑爆
    /// （例如程序休眠 8 小时后的补偿调用，按 1 小时封顶，宁可少算也不要污染平均值）。
    private static let maxInterval: TimeInterval = 3600

    /// 低于这个"影响"的应用条目不值得留档：既没有展示价值，又会在 180 天里累积成 MB 级文件。
    /// 0.02 CPU 秒 ≈ 一个真在干活的后台进程一小时里最少的量级；128MB 常驻内存则值得单独留一行。
    private static let appKeepCPUSeconds = 0.02
    private static let appKeepMemoryBytes: UInt64 = 128 * 1024 * 1024

    // MARK: - 状态

    private let directory: URL
    private let calendar: Calendar
    private let lock = NSLock()
    /// 所有磁盘写入都在这条串行队列上，保证追加 / 重写的顺序，并且永远不阻塞调用方。
    private let ioQueue = DispatchQueue(label: "com.litestats.history.io", qos: .utility)

    private var minuteRecords: [MinuteRecord] = []
    private var hourRecords: [BucketRecord] = []
    private var dayRecords: [BucketRecord] = []
    /// 小时桶：hourEpoch → 应用名 → 记录。用字典是为了"重复 start 合并"不需要线性查找。
    private var appHourRecords: [Int64: [String: AppBucketRecord]] = [:]
    private var appDayRecords: [Int64: [String: AppBucketRecord]] = [:]
    private var appPaths: [String: String] = [:]

    /// 每次 resetAll 自增。排队中的磁盘操作都带着自己的 generation，
    /// 清空之后旧操作直接作废，避免"删完文件又被追加回来"。
    private var generation: UInt64 = 0
    private var pendingOps: [PendingOp] = []

    // 实时累加器（尚未封口的部分）
    private var liveMinute: LiveAccumulator?
    private var liveHour: LiveAccumulator?
    private var liveDay: LiveAccumulator?
    private var liveAppHour: LiveAppBucket?
    private var liveAppDay: LiveAppBucket?
    /// 上一次做过保留策略清理的"自然日"。
    /// 单独记一个字段而不是依赖 liveDay 是否跨天：`flush()` 会把 liveDay 也封口清空，
    /// 那样跨天检测就丢了，过期数据会一直留着。
    private var lastPruneDay: Date?

    // MARK: - 内部类型

    /// 一拍的累加器。分钟 / 小时 / 天共用同一种结构，只是 start 粒度不同。
    private struct LiveAccumulator {
        var start: Date
        var cpuSeconds: Double = 0
        /// Σ(利用率 × 秒数)，即对时间的积分
        var gpuSeconds: Double = 0
        var memoryByteSeconds: Double = 0
        var networkIn: UInt64 = 0
        var networkOut: UInt64 = 0
        /// 实际累加进去的秒数（interval 之和），作为所有"平均"的分母
        var coveredSeconds: Double = 0
        var sampleCount: Int32 = 0
        var temperatureMax: Double?

        mutating func add(cpuSeconds: Double, gpuSeconds: Double, memoryByteSeconds: Double,
                          networkIn: UInt64, networkOut: UInt64, dt: Double, temperature: Double?) {
            self.cpuSeconds += cpuSeconds
            self.gpuSeconds += gpuSeconds
            self.memoryByteSeconds += memoryByteSeconds
            self.networkIn &+= networkIn
            self.networkOut &+= networkOut
            self.coveredSeconds += dt
            self.sampleCount &+= 1
            if let temperature, temperature.isFinite {
                self.temperatureMax = self.temperatureMax.map { max($0, temperature) } ?? temperature
            }
        }
    }

    private struct LiveApp {
        var path: String?
        var cpuSeconds: Double = 0
        var networkIn: UInt64 = 0
        var networkOut: UInt64 = 0
        var peakMemoryBytes: UInt64 = 0
        var sampleCount: Int32 = 0
    }

    private struct LiveAppBucket {
        var start: Date
        var apps: [String: LiveApp] = [:]
    }

    private enum FileKind: String, Hashable {
        case minutes = "minutes.bin"
        case hours = "hours.bin"
        case days = "days.bin"
        case appHours = "app-hours.bin"
        case appDays = "app-days.bin"
        case appNames = "app-names.bin"

        static let all: [FileKind] = [.minutes, .hours, .days, .appHours, .appDays, .appNames]

        func url(in directory: URL) -> URL {
            directory.appendingPathComponent(rawValue)
        }
    }

    private enum DiskPayload {
        /// 追加一批已经编码好的定长记录
        case append(Data)
        /// 用内存里的全部记录整体重写（清理过期数据 / 压缩）
        case rewriteAll
    }

    private struct PendingOp {
        let generation: UInt64
        let kind: FileKind
        let payload: DiskPayload
    }

    /// 区间汇总的中间结果。
    private struct Totals {
        var cpuSeconds: Double = 0
        var gpuSeconds: Double = 0
        var memoryByteSeconds: Double = 0
        var networkIn: UInt64 = 0
        var networkOut: UInt64 = 0
        var coveredSeconds: Double = 0
        var sampleCount: Int = 0

        mutating func add(cpuSeconds: Double, gpuSeconds: Double, memoryByteSeconds: Double,
                          networkIn: UInt64, networkOut: UInt64,
                          coveredSeconds: Double, sampleCount: Int, weight: Double) {
            self.cpuSeconds += cpuSeconds * weight
            self.gpuSeconds += gpuSeconds * weight
            self.memoryByteSeconds += memoryByteSeconds * weight
            self.networkIn &+= HistoryStore.scaledBytes(networkIn, weight: weight)
            self.networkOut &+= HistoryStore.scaledBytes(networkOut, weight: weight)
            self.coveredSeconds += coveredSeconds * weight
            self.sampleCount += sampleCount
        }

        var memoryBytesAverage: Double {
            coveredSeconds > 0 ? memoryByteSeconds / coveredSeconds : 0
        }
        var gpuPercentAverage: Double {
            coveredSeconds > 0 ? min(max(gpuSeconds / coveredSeconds, 0), 1) : 0
        }
    }

    // MARK: - 生命周期

    /// - Parameter directory: 历史数据的存放目录。nil 表示默认的
    ///   `~/Library/Application Support/LiteStats`；测试可以注入临时目录。
    ///   真正的数据文件放在该目录下的 `History/` 子目录里（便于设置界面整体展示 / 清理）。
    public init(directory: URL? = nil) throws {
        let base = try directory ?? Self.defaultDirectory()
        self.directory = base.appendingPathComponent("History", isDirectory: true)
        self.calendar = Calendar.current
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try loadFromDisk()
        lock.lock()
        // 启动时清一次过期数据（程序可能几天没开，期间的数据早该滚落了）。
        lastPruneDay = bucketStart(Date(), component: .day)
        pruneLocked(now: Date(), schedule: true)
        lock.unlock()
    }

    private static func defaultDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("LiteStats", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func loadFromDisk() throws {
        // 每个文件的读取互相独立：某个文件头对不上（换了格式 / 被破坏）只影响它自己，
        // 绝不因为"读不了历史"就让整个 App 起不来。
        func read<T>(_ kind: FileKind, magic: [UInt8], recordSize: Int,
                     decode: (UnsafeRawBufferPointer, Int) -> T?) -> [T] {
            let url = kind.url(in: directory)
            do {
                return try HistoryFileCodec.load(url, magic: magic,
                                                 recordSize: recordSize, decode: decode) ?? []
            } catch {
                let broken = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: url, to: broken)
                Self.log(error)
                return []
            }
        }

        let loadedMinutes = read(.minutes, magic: MinuteRecord.magic,
                                 recordSize: MinuteRecord.byteCount) { MinuteRecord(raw: $0, offset: $1) }
        let loadedHours = read(.hours, magic: BucketRecord.hourMagic,
                               recordSize: BucketRecord.byteCount) { BucketRecord(raw: $0, offset: $1) }
        let loadedDays = read(.days, magic: BucketRecord.dayMagic,
                              recordSize: BucketRecord.byteCount) { BucketRecord(raw: $0, offset: $1) }
        let loadedAppHours = read(.appHours, magic: AppBucketRecord.hourMagic,
                                  recordSize: AppBucketRecord.byteCount) { AppBucketRecord(raw: $0, offset: $1) }
        let loadedAppDays = read(.appDays, magic: AppBucketRecord.dayMagic,
                                 recordSize: AppBucketRecord.byteCount) { AppBucketRecord(raw: $0, offset: $1) }
        let loadedPaths = AppNameTable.load(FileKind.appNames.url(in: directory))

        lock.lock()
        defer { lock.unlock() }

        // 加载时同样做"同 start 合并"：flush() 可能把同一分钟封口过两次（见 mergeMinuteLocked 注释）。
        minuteRecords.removeAll()
        for record in loadedMinutes { mergeMinuteLocked(record, schedule: false) }
        hourRecords.removeAll()
        for record in loadedHours { mergeBucketLocked(record, into: &hourRecords) }
        dayRecords.removeAll()
        for record in loadedDays { mergeBucketLocked(record, into: &dayRecords) }
        appHourRecords.removeAll()
        for record in loadedAppHours { mergeAppLocked(record, into: &appHourRecords) }
        appDayRecords.removeAll()
        for record in loadedAppDays { mergeAppLocked(record, into: &appDayRecords) }
        appPaths = loadedPaths
    }

    // MARK: - 记录（主线程热路径）

    /// 记录一拍系统快照。内部按分钟聚合，只在"跨分钟 / 跨小时 / 跨天"时把封口的记录
    /// 丢给后台队列落盘，正常情况下不碰磁盘。
    ///
    /// - Parameter interval: 距上一次 `record` 的秒数；用来把"占用率"换算成"CPU 秒数"和"增量字节"。
    public func record(snapshot: SystemSnapshot, interval: TimeInterval) {
        let dt = Self.sanitizedInterval(interval)
        let timestamp = snapshot.timestamp

        lock.lock()

        let minuteStart = bucketStart(timestamp, component: .minute)
        let hourStart = bucketStart(timestamp, component: .hour)
        let dayStart = bucketStart(timestamp, component: .day)

        if let current = liveMinute, current.start != minuteStart { sealMinuteLocked() }
        if liveMinute == nil { liveMinute = LiveAccumulator(start: minuteStart) }

        if let current = liveHour, current.start != hourStart { sealHourLocked() }
        if liveHour == nil { liveHour = LiveAccumulator(start: hourStart) }

        if let current = liveDay, current.start != dayStart { sealDayLocked() }
        if liveDay == nil { liveDay = LiveAccumulator(start: dayStart) }

        // 跨天 → 清一次过期数据。判据用独立的 lastPruneDay（不受 flush() 把 liveDay 清空的影响）。
        if lastPruneDay != dayStart {
            lastPruneDay = dayStart
            pruneLocked(now: timestamp, schedule: true)
        }

        // CPU：total 是"整机 0...1"，乘核心数才是消耗掉的 CPU 秒数（8 核满载 1 秒 = 8 CPU 秒）。
        let coreCount = max(snapshot.cpu.coreCount, 0)
        let cpuSeconds = Self.sanitizedRatio(snapshot.cpu.total) * dt * Double(coreCount)
        // GPU 取不到时按 0 计（契约要求），不要让它变成 nil 污染积分。
        let gpuSeconds = Self.sanitizedRatio(snapshot.gpu.utilization ?? 0) * dt
        let memoryByteSeconds = Double(snapshot.memory.used) * dt
        let networkIn = Self.byteDelta(rate: snapshot.network.download, interval: dt)
        let networkOut = Self.byteDelta(rate: snapshot.network.upload, interval: dt)
        let temperature = snapshot.thermal.cpuTemperature

        liveMinute?.add(cpuSeconds: cpuSeconds, gpuSeconds: gpuSeconds,
                        memoryByteSeconds: memoryByteSeconds,
                        networkIn: networkIn, networkOut: networkOut,
                        dt: dt, temperature: temperature)
        liveHour?.add(cpuSeconds: cpuSeconds, gpuSeconds: gpuSeconds,
                      memoryByteSeconds: memoryByteSeconds,
                      networkIn: networkIn, networkOut: networkOut,
                      dt: dt, temperature: temperature)
        liveDay?.add(cpuSeconds: cpuSeconds, gpuSeconds: gpuSeconds,
                     memoryByteSeconds: memoryByteSeconds,
                     networkIn: networkIn, networkOut: networkOut,
                     dt: dt, temperature: temperature)

        lock.unlock()
    }

    /// 记录按应用的增量（由 `AppUsageCollector` 提供）。
    ///
    /// - Parameter interval: 距上一次采样的秒数。应用样本本身就是增量，所以这里只用它做
    ///   合法性校验（保留参数是为了契约稳定，将来若要按覆盖率折算会用到）。
    public func record(appSamples: [AppUsageSample], interval: TimeInterval) {
        guard !appSamples.isEmpty else { return }
        _ = Self.sanitizedInterval(interval)
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        let hourStart = bucketStart(now, component: .hour)
        let dayStart = bucketStart(now, component: .day)

        if let current = liveAppHour, current.start != hourStart { sealAppHourLocked() }
        if liveAppHour == nil { liveAppHour = LiveAppBucket(start: hourStart) }

        if let current = liveAppDay, current.start != dayStart { sealAppDayLocked() }
        if liveAppDay == nil { liveAppDay = LiveAppBucket(start: dayStart) }

        // 名字表一次采样只写一次（一批 100 个新名字只排 1 个磁盘任务，而不是 100 个）。
        var nameUpdates: [Data] = []
        for sample in appSamples {
            let name = sample.name
            guard !name.isEmpty else { continue }
            if let path = sample.path, !path.isEmpty, appPaths[name] != path {
                appPaths[name] = path
                nameUpdates.append(AppNameTable.encode(name: name, path: path))
            }
            var entry = liveAppHour?.apps[name] ?? LiveApp()
            let cpuSeconds = sample.cpuSeconds.isFinite ? max(0, sample.cpuSeconds) : 0
            entry.cpuSeconds += cpuSeconds
            entry.networkIn &+= sample.networkIn
            entry.networkOut &+= sample.networkOut
            entry.peakMemoryBytes = max(entry.peakMemoryBytes, sample.memoryBytes)
            entry.sampleCount &+= 1
            if entry.path == nil { entry.path = sample.path }
            liveAppHour?.apps[name] = entry
            liveAppDay?.apps[name] = entry
        }
        if !nameUpdates.isEmpty {
            var payload = Data()
            for chunk in nameUpdates { payload.append(chunk) }
            scheduleLocked(.appNames, .append(payload))
        }
    }

    // MARK: - 封口（锁内）

    private func sealMinuteLocked() {
        guard let accumulator = liveMinute else { return }
        var record = MinuteRecord()
        record.start = Int64(accumulator.start.timeIntervalSince1970)
        record.cpuSeconds = accumulator.cpuSeconds
        record.gpuSeconds = accumulator.gpuSeconds
        record.memoryByteSeconds = accumulator.memoryByteSeconds
        record.networkIn = accumulator.networkIn
        record.networkOut = accumulator.networkOut
        record.coveredSeconds = accumulator.coveredSeconds
        record.temperatureMax = accumulator.temperatureMax ?? .nan
        record.sampleCount = accumulator.sampleCount
        liveMinute = nil
        mergeMinuteLocked(record, schedule: true)
    }

    private func sealHourLocked() {
        guard let accumulator = liveHour else { return }
        var record = BucketRecord()
        record.start = Int64(accumulator.start.timeIntervalSince1970)
        record.cpuSeconds = accumulator.cpuSeconds
        record.gpuSeconds = accumulator.gpuSeconds
        record.memoryByteSeconds = accumulator.memoryByteSeconds
        record.networkIn = accumulator.networkIn
        record.networkOut = accumulator.networkOut
        record.coveredSeconds = accumulator.coveredSeconds
        record.sampleCount = accumulator.sampleCount
        liveHour = nil
        mergeBucketLocked(record, into: &hourRecords)
        scheduleLocked(.hours, .append(HistoryFileCodec.encodeRecords([record]) { $0.encoded() }))
    }

    private func sealDayLocked() {
        guard let accumulator = liveDay else { return }
        var record = BucketRecord()
        record.start = Int64(accumulator.start.timeIntervalSince1970)
        record.cpuSeconds = accumulator.cpuSeconds
        record.gpuSeconds = accumulator.gpuSeconds
        record.memoryByteSeconds = accumulator.memoryByteSeconds
        record.networkIn = accumulator.networkIn
        record.networkOut = accumulator.networkOut
        record.coveredSeconds = accumulator.coveredSeconds
        record.sampleCount = accumulator.sampleCount
        liveDay = nil
        mergeBucketLocked(record, into: &dayRecords)
        scheduleLocked(.days, .append(HistoryFileCodec.encodeRecords([record]) { $0.encoded() }))
    }

    private func sealAppHourLocked() {
        guard let bucket = liveAppHour else { return }
        liveAppHour = nil
        sealAppBucketLocked(bucket, into: &appHourRecords, kind: .appHours)
    }

    private func sealAppDayLocked() {
        guard let bucket = liveAppDay else { return }
        liveAppDay = nil
        sealAppBucketLocked(bucket, into: &appDayRecords, kind: .appDays)
    }

    private func sealAppBucketLocked(_ bucket: LiveAppBucket, into storage: inout [Int64: [String: AppBucketRecord]],
                                     kind: FileKind) {
        let start = Int64(bucket.start.timeIntervalSince1970)
        var encoded: [AppBucketRecord] = []
        for (name, usage) in bucket.apps where Self.shouldKeepApp(usage) {
            var record = AppBucketRecord()
            record.bucketStart = start
            record.cpuSeconds = usage.cpuSeconds
            record.networkIn = usage.networkIn
            record.networkOut = usage.networkOut
            record.peakMemoryBytes = usage.peakMemoryBytes
            record.sampleCount = usage.sampleCount
            record.nameBytes = AppBucketRecord.truncatedNameBytes(name)
            mergeAppLocked(record, into: &storage)
            encoded.append(record)
        }
        guard !encoded.isEmpty else { return }
        scheduleLocked(kind, .append(HistoryFileCodec.encodeRecords(encoded) { $0.encoded() }))
    }

    /// 是否值得给这个应用留一行历史。
    private static func shouldKeepApp(_ usage: LiveApp) -> Bool {
        usage.cpuSeconds >= appKeepCPUSeconds
            || usage.networkIn > 0
            || usage.networkOut > 0
            || usage.peakMemoryBytes >= appKeepMemoryBytes
    }

    /// 追加一条分钟记录。**同一个 start 必须合并**：
    /// `flush()` 会把当前这一分钟提前封口（保证退出前不丢数据），之后如果进程继续跑，
    /// 新的一拍又会用同一个 start 建累加器，于是磁盘上会出现两条 start 相同的记录。
    /// 内存里合并、加载时也合并，落盘时允许重复 —— 这样 flush 可以随便调。
    private func mergeMinuteLocked(_ record: MinuteRecord, schedule: Bool) {
        if var last = minuteRecords.last, last.start == record.start {
            last.merge(record)
            minuteRecords[minuteRecords.count - 1] = last
        } else {
            minuteRecords.append(record)
        }
        if schedule {
            scheduleLocked(.minutes, .append(HistoryFileCodec.encodeRecords([record]) { $0.encoded() }))
        }
    }

    private func mergeBucketLocked(_ record: BucketRecord, into storage: inout [BucketRecord]) {
        if var last = storage.last, last.start == record.start {
            last.merge(record)
            storage[storage.count - 1] = last
        } else {
            storage.append(record)
        }
    }

    private func mergeAppLocked(_ record: AppBucketRecord, into storage: inout [Int64: [String: AppBucketRecord]]) {
        var bucket = storage[record.bucketStart] ?? [:]
        let name = record.name
        guard !name.isEmpty else { return }
        if var existing = bucket[name] {
            existing.merge(record)
            bucket[name] = existing
        } else {
            bucket[name] = record
        }
        storage[record.bucketStart] = bucket
    }

    // MARK: - 保留策略

    /// 清理过期数据；需要整体重写文件时把 rewrite 操作排进后台队列。
    @discardableResult
    private func pruneLocked(now: Date, schedule: Bool) -> Set<FileKind> {
        let nowEpoch = now.timeIntervalSince1970
        var dirty: Set<FileKind> = []

        let minuteCutoff = nowEpoch - Self.minuteRetention
        if let first = minuteRecords.first, Double(first.start) < minuteCutoff {
            minuteRecords.removeAll { Double($0.start) < minuteCutoff }
            dirty.insert(.minutes)
        }
        let hourCutoff = nowEpoch - Self.hourRetention
        if let first = hourRecords.first, Double(first.start) < hourCutoff {
            hourRecords.removeAll { Double($0.start) < hourCutoff }
            dirty.insert(.hours)
        }
        let appHourCutoff = nowEpoch - Self.appHourRetention
        let staleAppHours = appHourRecords.keys.filter { Double($0) < appHourCutoff }
        if !staleAppHours.isEmpty {
            for key in staleAppHours { appHourRecords.removeValue(forKey: key) }
            dirty.insert(.appHours)
        }
        let appDayCutoff = nowEpoch - Self.appDayRetention
        let staleAppDays = appDayRecords.keys.filter { Double($0) < appDayCutoff }
        if !staleAppDays.isEmpty {
            for key in staleAppDays { appDayRecords.removeValue(forKey: key) }
            dirty.insert(.appDays)
        }
        // 天级永久保留：不清。

        if schedule {
            for kind in dirty { scheduleLocked(kind, .rewriteAll) }
        }
        return dirty
    }

    // MARK: - 查询

    /// 区间汇总。`from >= to` 时返回全 0 的空汇总。
    public func summary(from: Date, to: Date) -> UsageSummary {
        lock.lock()
        defer { lock.unlock() }
        return summaryLocked(from: from, to: to)
    }

    /// 今天（本地日历的 00:00 → now）。
    public func today(now: Date = Date()) -> UsageSummary {
        summary(from: bucketStart(now, component: .day), to: now)
    }

    /// 最近 `days` 个**自然日**（含今天）。lastDays(1) 就是 today()。
    public func lastDays(_ days: Int, now: Date = Date()) -> UsageSummary {
        let count = max(days, 1)
        let start = bucketStart(now, component: .day)
        let from = calendar.date(byAdding: .day, value: -(count - 1), to: start) ?? start
        return summary(from: from, to: now)
    }

    /// 最近 `hours` 小时的**滚动窗口**（不是自然小时对齐）。
    public func lastHours(_ hours: Int, now: Date = Date()) -> UsageSummary {
        let count = max(hours, 1)
        return summary(from: now.addingTimeInterval(-Double(count) * 3600), to: now)
    }

    /// 分钟级明细（额外接口，不在冻结清单里，纯增量）。
    /// 给 UI 画"今天哪一分钟最忙"的曲线用，也是单测里验证聚合语义的观察口。
    public func minuteSamples(from: Date, to: Date) -> [MinuteSample] {
        lock.lock()
        defer { lock.unlock() }
        let fromEpoch = from.timeIntervalSince1970
        let toEpoch = to.timeIntervalSince1970
        guard toEpoch > fromEpoch else { return [] }
        var result: [MinuteSample] = []
        for record in minuteRecords {
            let (overlaps, weight) = Self.overlap(start: Double(record.start), duration: 60,
                                                  from: fromEpoch, to: toEpoch)
            guard overlaps else { continue }
            result.append(MinuteSample(
                date: Date(timeIntervalSince1970: Double(record.start)),
                cpuSeconds: record.cpuSeconds * weight,
                gpuPercentAverage: record.coveredSeconds > 0
                    ? min(max(record.gpuSeconds / record.coveredSeconds, 0), 1) : 0,
                memoryBytesAverage: record.coveredSeconds > 0
                    ? record.memoryByteSeconds / record.coveredSeconds : 0,
                networkIn: Self.scaledBytes(record.networkIn, weight: weight),
                networkOut: Self.scaledBytes(record.networkOut, weight: weight),
                temperatureMax: record.temperatureMax.isFinite ? record.temperatureMax : nil))
        }
        // 当前还没封口的那一分钟也要返回，否则"刚刚发生的事"在分钟曲线上要等到下一分钟才出现。
        if let live = liveMinute, liveOverlaps(live, fromEpoch: fromEpoch, toEpoch: toEpoch) {
            result.append(MinuteSample(
                date: live.start,
                cpuSeconds: live.cpuSeconds,
                gpuPercentAverage: live.coveredSeconds > 0
                    ? min(max(live.gpuSeconds / live.coveredSeconds, 0), 1) : 0,
                memoryBytesAverage: live.coveredSeconds > 0
                    ? live.memoryByteSeconds / live.coveredSeconds : 0,
                networkIn: live.networkIn,
                networkOut: live.networkOut,
                temperatureMax: live.temperatureMax))
        }
        return result
    }

    // MARK: - 汇总实现（锁内）

    private func summaryLocked(from: Date, to: Date) -> UsageSummary {
        let fromEpoch = from.timeIntervalSince1970
        let toEpoch = to.timeIntervalSince1970
        guard toEpoch > fromEpoch else { return .empty(from: from, to: to) }

        var totals = Totals()
        var hourlyTotals: [Int64: Totals] = [:]

        func addToHour(_ key: Int64, _ record: (cpu: Double, gpu: Double, memBytes: Double,
                                                netIn: UInt64, netOut: UInt64,
                                                covered: Double, samples: Int), weight: Double) {
            hourlyTotals[key, default: Totals()].add(
                cpuSeconds: record.cpu, gpuSeconds: record.gpu,
                memoryByteSeconds: record.memBytes,
                networkIn: record.netIn, networkOut: record.netOut,
                coveredSeconds: record.covered, sampleCount: record.samples, weight: weight)
        }

        // 1) 分钟级明细（最近 7 天）。存的是积分，按重叠比例缩放不会破坏平均值。
        for record in minuteRecords {
            let (overlaps, weight) = Self.overlap(start: Double(record.start), duration: 60,
                                                  from: fromEpoch, to: toEpoch)
            guard overlaps else { continue }
            let values = (cpu: record.cpuSeconds, gpu: record.gpuSeconds,
                          memBytes: record.memoryByteSeconds,
                          netIn: record.networkIn, netOut: record.networkOut,
                          covered: record.coveredSeconds, samples: Int(record.sampleCount))
            totals.add(cpuSeconds: values.cpu, gpuSeconds: values.gpu,
                       memoryByteSeconds: values.memBytes,
                       networkIn: values.netIn, networkOut: values.netOut,
                       coveredSeconds: values.covered, sampleCount: values.samples, weight: weight)
            addToHour(hourKey(forEpoch: Double(record.start)), values, weight: weight)
        }

        // 2) 未封口的当前分钟：它只覆盖了 [start, start+covered)，不能再按整分钟打折，
        //    否则会把"刚记了 5 秒"的那一分钟算成 1/12。
        if let live = liveMinute, liveOverlaps(live, fromEpoch: fromEpoch, toEpoch: toEpoch) {
            let values = (cpu: live.cpuSeconds, gpu: live.gpuSeconds,
                          memBytes: live.memoryByteSeconds,
                          netIn: live.networkIn, netOut: live.networkOut,
                          covered: live.coveredSeconds, samples: Int(live.sampleCount))
            totals.add(cpuSeconds: values.cpu, gpuSeconds: values.gpu,
                       memoryByteSeconds: values.memBytes,
                       networkIn: values.netIn, networkOut: values.netOut,
                       coveredSeconds: values.covered, sampleCount: values.samples, weight: 1)
            addToHour(hourKey(forEpoch: live.start.timeIntervalSince1970), values, weight: 1)
        }

        // 3) 小时级：只取"分钟明细完全覆盖不到"的那一段。
        //    判据是 `hourEnd <= minuteCoverStart`，而不是"小时起点在分钟窗口之后"：
        //    跨在边界上的那一小时会被分钟和小时各算一遍（实测就是 2 倍），
        //    宁可把边界那一小时让给更精确的分钟明细。
        let minuteCoverEnd = minuteRecords.first.map { Double($0.start) }
        for record in hourRecords {
            let start = hourStart(ofEpoch: Double(record.start))
            let end = start + hourDuration(ofEpoch: Double(record.start))
            if let minuteCoverEnd, end > minuteCoverEnd { continue }
            let (overlaps, weight) = Self.overlap(start: start, duration: end - start,
                                                  from: fromEpoch, to: toEpoch)
            guard overlaps else { continue }
            let values = (cpu: record.cpuSeconds, gpu: record.gpuSeconds,
                          memBytes: record.memoryByteSeconds,
                          netIn: record.networkIn, netOut: record.networkOut,
                          covered: record.coveredSeconds, samples: Int(record.sampleCount))
            totals.add(cpuSeconds: values.cpu, gpuSeconds: values.gpu,
                       memoryByteSeconds: values.memBytes,
                       networkIn: values.netIn, networkOut: values.netOut,
                       coveredSeconds: values.covered, sampleCount: values.samples, weight: weight)
            addToHour(hourKey(forEpoch: Double(record.start)), values, weight: weight)
        }

        // 4) 天级：只取"小时明细完全覆盖不到"的那一段（180 天以前）。
        let hourCoverEnd = hourRecords.first.map { Double($0.start) }
        for record in dayRecords {
            let start = dayStart(ofEpoch: Double(record.start))
            let end = start + dayDuration(ofEpoch: Double(record.start))
            if let hourCoverEnd, end > hourCoverEnd { continue }
            let (overlaps, weight) = Self.overlap(start: start, duration: end - start,
                                                  from: fromEpoch, to: toEpoch)
            guard overlaps else { continue }
            totals.add(cpuSeconds: record.cpuSeconds, gpuSeconds: record.gpuSeconds,
                       memoryByteSeconds: record.memoryByteSeconds,
                       networkIn: record.networkIn, networkOut: record.networkOut,
                       coveredSeconds: record.coveredSeconds,
                       sampleCount: Int(record.sampleCount), weight: weight)
        }

        // 5) 按应用：小时明细（7 天）+ 天明细（180 天），同一段时间不重复计。
        var appTotals: [String: (cpu: Double, netIn: UInt64, netOut: UInt64,
                                 peakMemory: UInt64, samples: Int)] = [:]
        let appHourCoverEnd = appHourRecords.keys.min().map { Double($0) }

        func accumulateApp(_ record: AppBucketRecord, weight: Double) {
            let name = record.name
            guard !name.isEmpty else { return }
            var entry = appTotals[name] ?? (0, 0, 0, 0, 0)
            entry.cpu += record.cpuSeconds * weight
            entry.netIn &+= Self.scaledBytes(record.networkIn, weight: weight)
            entry.netOut &+= Self.scaledBytes(record.networkOut, weight: weight)
            entry.peakMemory = max(entry.peakMemory, record.peakMemoryBytes)
            entry.samples += Int(record.sampleCount)
            appTotals[name] = entry
        }

        for (key, bucket) in appHourRecords {
            let (overlaps, weight) = Self.overlap(start: hourStart(ofEpoch: Double(key)),
                                                  duration: hourDuration(ofEpoch: Double(key)),
                                                  from: fromEpoch, to: toEpoch)
            guard overlaps else { continue }
            for record in bucket.values { accumulateApp(record, weight: weight) }
        }
        for (key, bucket) in appDayRecords {
            let start = dayStart(ofEpoch: Double(key))
            let end = start + dayDuration(ofEpoch: Double(key))
            if let appHourCoverEnd, end > appHourCoverEnd { continue }
            let (overlaps, weight) = Self.overlap(start: start, duration: end - start,
                                                  from: fromEpoch, to: toEpoch)
            guard overlaps else { continue }
            for record in bucket.values { accumulateApp(record, weight: weight) }
        }
        // 未封口的当前小时同样要算进去，否则"今天"的 Top 应用要等到整点才出现。
        if let live = liveAppHour, liveOverlaps(live, fromEpoch: fromEpoch, toEpoch: toEpoch) {
            for (name, usage) in live.apps where Self.shouldKeepApp(usage) {
                var entry = appTotals[name] ?? (0, 0, 0, 0, 0)
                entry.cpu += usage.cpuSeconds
                entry.netIn &+= usage.networkIn
                entry.netOut &+= usage.networkOut
                entry.peakMemory = max(entry.peakMemory, usage.peakMemoryBytes)
                entry.samples += Int(usage.sampleCount)
                appTotals[name] = entry
            }
        }

        let apps = appTotals.map { name, value -> AppUsage in
            AppUsage(name: name, path: appPaths[name], cpuSeconds: value.cpu,
                     peakMemoryBytes: value.peakMemory,
                     networkIn: value.netIn, networkOut: value.netOut,
                     sampleCount: value.samples)
        }.sorted { lhs, rhs in
            let left = HistoryRanking.impactWeight(lhs)
            let right = HistoryRanking.impactWeight(rhs)
            if left != right { return left > right }
            return lhs.name < rhs.name          // 权重相同时按名字，保证顺序稳定
        }

        let hourly = hourlyTotals.map { key, value in
            HourlyBucket(hourStart: Date(timeIntervalSince1970: Double(key)),
                         cpuSeconds: value.cpuSeconds,
                         gpuPercentAverage: value.gpuPercentAverage,
                         memoryBytesAverage: value.memoryBytesAverage,
                         networkIn: value.networkIn,
                         networkOut: value.networkOut,
                         sampleCount: value.sampleCount)
        }.sorted { $0.hourStart < $1.hourStart }

        return UsageSummary(rangeStart: from, rangeEnd: to,
                            networkIn: totals.networkIn, networkOut: totals.networkOut,
                            cpuSeconds: totals.cpuSeconds, gpuSeconds: totals.gpuSeconds,
                            memoryBytesAverage: totals.memoryBytesAverage,
                            hourly: hourly, apps: apps,
                            trackDuration: totals.coveredSeconds)
    }

    /// 未封口累加器是否落在查询区间内。它只覆盖 [start, start+covered)，所以"整条算进去"即可。
    private func liveOverlaps(_ accumulator: LiveAccumulator, fromEpoch: Double, toEpoch: Double) -> Bool {
        let start = accumulator.start.timeIntervalSince1970
        let end = start + max(accumulator.coveredSeconds, 0)
        return start < toEpoch && end > fromEpoch
    }

    private func liveOverlaps(_ bucket: LiveAppBucket, fromEpoch: Double, toEpoch: Double) -> Bool {
        let start = bucket.start.timeIntervalSince1970
        return start < toEpoch && start + 3600 > fromEpoch
    }

    // MARK: - 清空 / 落盘 / 存储信息

    /// 清空全部历史（删文件 + 清内存），供设置界面的"清空数据"按钮用。
    public func resetAll() throws {
        lock.lock()
        generation &+= 1
        pendingOps.removeAll()
        minuteRecords.removeAll()
        hourRecords.removeAll()
        dayRecords.removeAll()
        appHourRecords.removeAll()
        appDayRecords.removeAll()
        appPaths.removeAll()
        liveMinute = nil
        liveHour = nil
        liveDay = nil
        liveAppHour = nil
        liveAppDay = nil
        lock.unlock()

        // 串行队列 sync 一次：等在途的写操作跑完（它们会看到新的 generation 而自我作废），
        // 再删文件。这样不会有"删完又被追加回来"的竞态。
        var thrown: Error?
        ioQueue.sync {
            for kind in FileKind.all {
                let url = kind.url(in: directory)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do { try FileManager.default.removeItem(at: url) } catch { thrown = error }
            }
        }
        if let thrown { throw thrown }
    }

    /// 落盘（退出前调用，确保最后一段数据不丢）。
    /// 会把当前未满的分钟 / 小时 / 天 / 应用桶提前封口；之后再 record 同一分钟也没问题
    /// （内存与加载都会合并同 start 的记录）。
    public func flush() {
        lock.lock()
        sealMinuteLocked()
        sealHourLocked()
        sealDayLocked()
        sealAppHourLocked()
        sealAppDayLocked()
        lock.unlock()
        ioQueue.sync {}          // 排空队列
    }

    /// 存储目录，给设置界面显示。
    public var storagePath: String { directory.path }

    /// 默认存储目录的路径（拿不到就返回字面量），给界面提示用
    public static var defaultStoragePath: String {
        (try? defaultDirectory())?.appendingPathComponent("History").path
            ?? "~/Library/Application Support/LiteStats/History"
    }

    /// 历史文件占用的总字节数。
    public var storageBytes: UInt64 {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                             options: []) else { return 0 }
        var total: UInt64 = 0
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if let size = values?.fileSize, values?.isRegularFile == true {
                total &+= UInt64(max(size, 0))
            }
        }
        return total
    }

    /// 各层记录条数。仅测试与诊断使用（不属于冻结契约）。
    var debugRecordCounts: (minutes: Int, hours: Int, days: Int, appHours: Int, appDays: Int, names: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (minuteRecords.count, hourRecords.count, dayRecords.count,
                appHourRecords.values.reduce(0) { $0 + $1.count },
                appDayRecords.values.reduce(0) { $0 + $1.count },
                appPaths.count)
    }

    /// 手动触发一次清理（仅测试使用；正常运行由 init / 跨天自动触发）。
    func pruneForTesting(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now, schedule: true)
    }

    // MARK: - 磁盘 I/O（后台串行队列）

    private func scheduleLocked(_ kind: FileKind, _ payload: DiskPayload) {
        pendingOps.append(PendingOp(generation: generation, kind: kind, payload: payload))
        ioQueue.async { [weak self] in self?.drainPending() }
    }

    private func drainPending() {
        lock.lock()
        guard !pendingOps.isEmpty else { lock.unlock(); return }
        let ops = pendingOps
        pendingOps.removeAll(keepingCapacity: true)
        let currentGeneration = generation
        // 重写需要内存里的全量快照，直接在锁内取（都是 POD 数组，拷贝是 memcpy 级别）。
        var rewrites: [FileKind: Data] = [:]
        for op in ops where op.generation == currentGeneration {
            if case .rewriteAll = op.payload, rewrites[op.kind] == nil {
                rewrites[op.kind] = rewritePayloadLocked(op.kind)
            }
        }
        lock.unlock()

        for op in ops where op.generation == currentGeneration {
            switch op.payload {
            case .append(let data):
                do { try Self.append(data, to: op.kind.url(in: directory)) } catch { Self.log(error) }
            case .rewriteAll:
                // ⚠️ 名字表是"只追加"的，它的 rewritePayloadLocked 返回空 Data。
                // 如果在这里照常写下去，一次压缩/清理就会把整张名字表清空
                // —— 表现为重启后所有应用的 path 全丢（名字还在，路径没了）。
                if op.kind == .appNames { continue }
                guard let data = rewrites[op.kind] else { continue }
                do { try data.write(to: op.kind.url(in: directory), options: .atomic) } catch { Self.log(error) }
            }
        }
    }

    /// 锁内：把某一类记录编码成完整文件内容。
    private func rewritePayloadLocked(_ kind: FileKind) -> Data {
        switch kind {
        case .minutes:
            return HistoryFileCodec.encode(minuteRecords, magic: MinuteRecord.magic,
                                           recordSize: MinuteRecord.byteCount) { $0.encoded() }
        case .hours:
            return HistoryFileCodec.encode(hourRecords, magic: BucketRecord.hourMagic,
                                           recordSize: BucketRecord.byteCount) { $0.encoded() }
        case .days:
            return HistoryFileCodec.encode(dayRecords, magic: BucketRecord.dayMagic,
                                           recordSize: BucketRecord.byteCount) { $0.encoded() }
        case .appHours:
            var all: [AppBucketRecord] = []
            for bucket in appHourRecords.values { all.append(contentsOf: bucket.values) }
            all.sort { $0.bucketStart < $1.bucketStart }
            return HistoryFileCodec.encode(all, magic: AppBucketRecord.hourMagic,
                                           recordSize: AppBucketRecord.byteCount) { $0.encoded() }
        case .appDays:
            var all: [AppBucketRecord] = []
            for bucket in appDayRecords.values { all.append(contentsOf: bucket.values) }
            all.sort { $0.bucketStart < $1.bucketStart }
            return HistoryFileCodec.encode(all, magic: AppBucketRecord.dayMagic,
                                           recordSize: AppBucketRecord.byteCount) { $0.encoded() }
        case .appNames:
            return Data()      // 名字表只追加，不需要压缩重写
        }
    }

    /// 追加写：文件不存在时先补一个文件头。
    private static func append(_ payload: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            var header = [UInt8]()
            header.append(contentsOf: magic(for: url.lastPathComponent))
            header.appendU32(HistoryFileCodec.version)
            header.appendU32(UInt32(recordSize(for: url.lastPathComponent)))
            header.appendU32(0)
            try Data(header).write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }

    private static func magic(for fileName: String) -> [UInt8] {
        switch fileName {
        case MinuteRecord.fileName: return MinuteRecord.magic
        case BucketRecord.hourFileName: return BucketRecord.hourMagic
        case BucketRecord.dayFileName: return BucketRecord.dayMagic
        case AppBucketRecord.hourFileName: return AppBucketRecord.hourMagic
        case AppBucketRecord.dayFileName: return AppBucketRecord.dayMagic
        case AppNameTable.fileName: return AppNameTable.magic
        default: return Array("LS??".utf8)
        }
    }

    private static func recordSize(for fileName: String) -> Int {
        switch fileName {
        case MinuteRecord.fileName: return MinuteRecord.byteCount
        case BucketRecord.hourFileName, BucketRecord.dayFileName: return BucketRecord.byteCount
        case AppBucketRecord.hourFileName, AppBucketRecord.dayFileName: return AppBucketRecord.byteCount
        default: return 0
        }
    }

    private static func log(_ error: Error) {
        FileHandle.standardError.write(Data(("历史数据落盘失败：\(error)\n").utf8))
    }

    // MARK: - 小工具

    private func bucketStart(_ date: Date, component: Calendar.Component) -> Date {
        calendar.dateInterval(of: component, for: date)?.start ?? date
    }

    private func hourKey(forEpoch epoch: Double) -> Int64 {
        Int64(bucketStart(Date(timeIntervalSince1970: epoch), component: .hour).timeIntervalSince1970)
    }

    private func hourStart(ofEpoch epoch: Double) -> Double {
        bucketStart(Date(timeIntervalSince1970: epoch), component: .hour).timeIntervalSince1970
    }

    private func hourDuration(ofEpoch epoch: Double) -> Double {
        calendar.dateInterval(of: .hour, for: Date(timeIntervalSince1970: epoch))?.duration ?? 3600
    }

    private func dayStart(ofEpoch epoch: Double) -> Double {
        bucketStart(Date(timeIntervalSince1970: epoch), component: .day).timeIntervalSince1970
    }

    private func dayDuration(ofEpoch epoch: Double) -> Double {
        calendar.dateInterval(of: .day, for: Date(timeIntervalSince1970: epoch))?.duration ?? 86400
    }

    /// 区间 [start, start+duration) 与 [from, to) 的重叠比例（0...1）。
    ///
    /// ⚠️ 只按**桶起点被截掉多少**折算，尾部整体计入：
    /// 我们无法区分"桶还没记满"和"桶已经记满但查询区间提前结束"，
    /// 而用户的查询（today / lastHours / lastDays）结尾永远是 `now`，
    /// 所以"尾部整体计入"才是对的；按尾部截断会在"当前这一小时只过了 45 分钟"时
    /// 把已经采到的数据再打折（实测把 2.5 CPU 秒算成 1.875）。
    private static func overlap(start: Double, duration: Double,
                                from: Double, to: Double) -> (Bool, Double) {
        guard duration > 0 else { return (false, 0) }
        guard start < to, start + duration > from else { return (false, 0) }
        let effectiveStart = max(start, from)
        return (true, min(max((start + duration - effectiveStart) / duration, 0), 1))
    }

    /// 把计数值按权重缩放成字节数，带饱和保护（不产生 NaN / 溢出陷阱）。
    private static func scaledBytes(_ value: UInt64, weight: Double) -> UInt64 {
        guard weight.isFinite, weight > 0 else { return 0 }
        if weight >= 1 { return value }
        let scaled = (Double(value) * weight).rounded()
        guard scaled.isFinite, scaled > 0 else { return 0 }
        return scaled >= Double(UInt64.max) ? UInt64.max : UInt64(scaled)
    }

    private static func sanitizedInterval(_ interval: TimeInterval) -> Double {
        guard interval.isFinite, interval > 0 else { return 0 }
        return min(interval, maxInterval)
    }

    private static func sanitizedRatio(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(value, 1)
    }

    /// 速率 × 时长 → 增量字节。任何异常值（NaN / 溢出）都退化成 0。
    private static func byteDelta(rate: Double, interval: Double) -> UInt64 {
        guard rate.isFinite, rate > 0, interval > 0 else { return 0 }
        let value = (rate * interval).rounded()
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }
}
