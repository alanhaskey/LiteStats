// 按应用采样的门面：把 libproc（CPU / 内存）和 nettop（网络）合成 `[AppUsageSample]`。
//
// 采样策略：
//   * CPU / 内存每拍都采（实测 0.5 ms 量级，无感）；
//   * 网络每 N 拍才跑一次 nettop（一次 ~13 ms，没必要每拍 fork 一个进程）。
//
// ⚠️ 两个"差分"细节（两边给的都是累计值，必须差分）：
//   1. CPU：ri_user_time / ri_system_time 是进程启动以来的累计值；
//   2. 网络：nettop 的 bytes_in / bytes_out 同样是进程启动以来的累计值。
//   所以第一次 `sample()` 只能建立基线、返回空数组；而且**如果 nettop 失败了，
//   基线要保留而不是清空** —— 下次成功时差分出来的增量覆盖整段间隔，总量依然是对的。
//
// ⚠️ PID 复用：只用 pid 做 key 是错的（pid 会被回收，新进程会继承旧进程的 pid），
//   所以 key 用 `(pid, 进程名)`；pid 相同但名字变了就当新进程，重新建基线。
//
// ⚠️ nettop 会把进程名截断到 15 个字符（实测 "DSH Desktop Helper" → "DSH Desktop Hel"），
//   直接用它会把同一个应用拆成"有 CPU 的"和"有网络的"两条，
//   所以要用同一拍 libproc 采到的 pid → 完整进程名把名字归一化回来。
import Foundation

/// 采集当前正在运行的进程的 CPU / 内存 / 网络增量。
/// 线程安全（内部 NSLock）；不抛错、不崩溃，任何一步失败都降级。
public final class AppUsageCollector: @unchecked Sendable {

    /// (pid, 进程名) 组合键。见文件头"PID 复用"的说明。
    private struct ProcessKey: Hashable {
        let pid: Int32
        let name: String
    }

    private struct Aggregate {
        var path: String?
        var cpuSeconds: Double = 0
        var memoryBytes: UInt64 = 0
        var networkIn: UInt64 = 0
        var networkOut: UInt64 = 0
    }

    private let lock = NSLock()
    private let nettopPath: String
    private let nettopEveryNSamples: Int

    private var samplesTaken = 0
    private var nettopRuns = 0
    private var processBaseline: [ProcessKey: (cpuSeconds: Double, memoryBytes: UInt64)] = [:]
    /// nettop 的累计值基线，key 为 "pid|nettop 里的名字"。
    private var netBaseline: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]

    /// - Parameter nettopEveryNSamples: 每 N 次 `sample()` 才跑一次 nettop（默认 6）。
    public init(nettopEveryNSamples: Int = 6) {
        self.nettopPath = NettopSampler.defaultExecutable
        self.nettopEveryNSamples = max(1, nettopEveryNSamples)
    }

    /// 额外接口（不在冻结清单里，纯增量）：注入 nettop 路径，供降级测试与自定义安装路径使用。
    public init(nettopPath: String, nettopEveryNSamples: Int = 6) {
        self.nettopPath = nettopPath
        self.nettopEveryNSamples = max(1, nettopEveryNSamples)
    }

    /// 采一次，返回**自上次调用以来的增量**。
    /// 第一次调用只建立基线、返回空数组（这是契约行为，不是"没采到"）。
    public func sample() -> [AppUsageSample] {
        lock.lock()
        defer { lock.unlock() }

        samplesTaken += 1
        let isBaseline = samplesTaken == 1

        // MARK: CPU / 内存（每拍）
        let counters = ProcessSampler.sample()
        var nextProcessBaseline: [ProcessKey: (cpuSeconds: Double, memoryBytes: UInt64)] = [:]
        nextProcessBaseline.reserveCapacity(counters.count)
        var aggregates: [String: Aggregate] = [:]
        aggregates.reserveCapacity(counters.count)
        var namesByPid: [Int32: String] = [:]
        namesByPid.reserveCapacity(counters.count)

        for counter in counters {
            let key = ProcessKey(pid: counter.pid, name: counter.name)
            nextProcessBaseline[key] = (counter.cpuSeconds, counter.memoryBytes)
            namesByPid[counter.pid] = counter.name

            var aggregate = aggregates[counter.name] ?? Aggregate()
            // 同名进程（Chrome Helper 之类）的内存相加，得到"这个应用占了多少内存"。
            aggregate.memoryBytes &+= counter.memoryBytes
            if aggregate.path == nil { aggregate.path = counter.path }
            if !isBaseline, let previous = processBaseline[key] {
                // 进程重启后累计值会变小 → 负增量按 0 处理（宁可少算，也不要出现负值）。
                let delta = counter.cpuSeconds - previous.cpuSeconds
                if delta > 0, delta.isFinite { aggregate.cpuSeconds += delta }
            }
            aggregates[counter.name] = aggregate
        }

        // MARK: 网络（每 N 拍）
        if (samplesTaken - 1) % nettopEveryNSamples == 0 {
            runNettopLocked(namesByPid: namesByPid, into: &aggregates)
        }

        processBaseline = nextProcessBaseline
        guard !isBaseline else { return [] }

        return aggregates.map { name, value in
            AppUsageSample(name: name, path: value.path, cpuSeconds: value.cpuSeconds,
                           memoryBytes: value.memoryBytes,
                           networkIn: value.networkIn, networkOut: value.networkOut)
        }.sorted { $0.name < $1.name }     // 顺序稳定，便于测试与 diff
    }

    /// 清空基线：下一次 `sample()` 重新当基线（返回空数组）。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samplesTaken = 0
        nettopRuns = 0
        processBaseline.removeAll()
        netBaseline.removeAll()
    }

    // MARK: - nettop 差分（锁内）

    private func runNettopLocked(namesByPid: [Int32: String], into aggregates: inout [String: Aggregate]) {
        let snapshot = NettopSampler.sample(executable: nettopPath)
        // 失败（路径不存在 / 启动失败 / 输出不可解析）→ 空数组。
        // 此时**不动 netBaseline**：下次成功时差分覆盖整段间隔，总量仍然正确。
        guard !snapshot.isEmpty else { return }
        nettopRuns += 1

        let result = Self.diffNettop(previous: netBaseline, current: snapshot, namesByPid: namesByPid)
        netBaseline = result.baseline
        for (name, delta) in result.deltas {
            var aggregate = aggregates[name] ?? Aggregate()
            aggregate.networkIn &+= delta.in
            aggregate.networkOut &+= delta.out
            aggregates[name] = aggregate
        }
    }

    /// 纯函数（便于单测）：两拍 nettop 累计值求差，并按归一化后的应用名合并。
    ///
    /// - Parameters:
    ///   - previous: 上一拍的累计值，key = `"pid|nettop 名字"`
    ///   - current: 本拍的累计值
    ///   - namesByPid: 同一拍 libproc 采到的 pid → 完整进程名（修复 nettop 的 15 字符截断）
    /// - Returns: `deltas`（应用名 → 增量）与新的基线。
    ///   计数变小（进程重启）按 0 处理；第一次见到的 pid 只建基线、不产生增量。
    static func diffNettop(previous: [String: (bytesIn: UInt64, bytesOut: UInt64)],
                           current: [NettopProcessCounters],
                           namesByPid: [Int32: String])
        -> (deltas: [String: (in: UInt64, out: UInt64)],
            baseline: [String: (bytesIn: UInt64, bytesOut: UInt64)]) {
        var baseline: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        baseline.reserveCapacity(current.count)
        var deltas: [String: (in: UInt64, out: UInt64)] = [:]

        for entry in current {
            let key = "\(entry.pid)|\(entry.name)"
            baseline[key] = (entry.bytesIn, entry.bytesOut)
            guard let last = previous[key] else { continue }
            let deltaIn = entry.bytesIn >= last.bytesIn ? entry.bytesIn - last.bytesIn : 0
            let deltaOut = entry.bytesOut >= last.bytesOut ? entry.bytesOut - last.bytesOut : 0
            guard deltaIn > 0 || deltaOut > 0 else { continue }

            let name = namesByPid[entry.pid] ?? entry.name
            var merged = deltas[name] ?? (0, 0)
            merged.in &+= deltaIn
            merged.out &+= deltaOut
            deltas[name] = merged
        }
        return (deltas, baseline)
    }

    // MARK: - 诊断（仅测试可见）

    /// nettop 成功跑过的次数，用来验证"降级成只有 CPU / 内存"。
    var debugNettopRuns: Int {
        lock.lock()
        defer { lock.unlock() }
        return nettopRuns
    }
}
