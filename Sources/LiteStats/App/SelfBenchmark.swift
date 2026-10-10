import AppKit
import Darwin

/// 自身开销测量。`--benchmark [秒数]` 会跑真实的 App 流程（面板 + 采样），
/// 分「收起态 → 展开态 → 再收起」三段报告 CPU 时间与内存，然后退出。
///
/// 为什么自己测：macOS 上没有特殊授权时外部拿不到别的进程的 CPU/内存
/// （本机沙箱里 `ps`/`top` 也被禁止），而 `task_info(mach_task_self())`
/// 是内核给出的权威数据，等价于活动监视器看到的数字。
@MainActor
enum SelfBenchmark {
    static func requestedSeconds() -> Double? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--benchmark") else { return nil }
        if idx + 1 < args.count, let value = Double(args[idx + 1]), value > 0 { return value }
        return 30
    }

    /// 返回 (CPU 秒数累计, 常驻内存 RSS)
    ///
    /// CPU 时间用 POSIX `getrusage(RUSAGE_SELF)`：实测 `task_info(MACH_TASK_BASIC_INFO)`
    /// 的 user_time/system_time 在本机（macOS 27 / Apple Silicon）会长时间不更新，
    /// 出现"明明采样了 8 次却报告 0 ms CPU"的假数据。
    static func cpuSecondsAndRSS() -> (cpu: Double, rss: UInt64) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return (cpu, result == KERN_SUCCESS ? info.resident_size : 0)
    }

    /// 物理占用（phys_footprint）—— 活动监视器「内存」列的口径，
    /// 比 RSS 更能反映真实代价（RSS 会把共享缓存里驻留的页也算进来）。
    static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func run(totalSeconds: Double, service: MonitorService, controller: NotchPanelController) {
        controller.hoverEnabled = false // 保证各段状态可控、结果可复现
        print("[bench] LiteStats 自身开销测量，共 \(Int(totalSeconds))s（6 段）")
        print("[bench] 采样间隔：收起 \(service.intervalCollapsed)s / 展开 \(service.intervalExpanded)s")
        BenchmarkRunner(service: service, controller: controller,
                        phaseSeconds: max(3, totalSeconds / 6)).start()
    }
}

@MainActor
private final class BenchmarkRunner {
    private let service: MonitorService
    private let controller: NotchPanelController
    private let phaseSeconds: Double

    private let phases: [(title: String, apply: () -> Void)] = [
        ("① 完全空闲（采样器 + 悬浮轮询全停）", {}),
        ("② 收起态常驻（采样 2s + 悬浮轮询 0.1s）", {}),
        ("③ 展开态（面板渲染中，采样 1s）", {}),
        ("④ 再收起（看内存是否回落）", {}),
        ("⑤ 展开但停止采样（区分“持续重绘”与“每次更新重绘”）", {}),
        ("⑥ 展开 + 温度高频刷新（有人看温度/风扇）", {}),
    ]

    private var index = 0
    private var samplesAtStart = 0
    private var cpuAtStart: Double = 0
    private var wallAtStart = Date()

    init(service: MonitorService, controller: NotchPanelController, phaseSeconds: Double) {
        self.service = service
        self.controller = controller
        self.phaseSeconds = phaseSeconds
    }

    func start() {
        // ① 完全空闲：停掉采样器与轮询定时器，测 AppKit/SwiftUI 的空转地板
        controller.setPollingEnabled(false)
        service.stop()
        next()
    }

    private func next() {
        guard index < phases.count else {
            finish()
            return
        }
        let title = phases[index].title
        switch index {
        case 1:
            // ② 恢复常驻：采样 2s + 悬浮轮询 0.1s，面板保持收起
            controller.setPollingEnabled(true)
            controller.forceState(.collapsed, animated: false)
            service.isPanelExpanded = false
            service.start()
        case 2:
            // ③ 展开
            controller.forceState(.expanded, animated: false)
            service.isPanelExpanded = true
        case 3:
            // ④ 收起
            controller.forceState(.collapsed, animated: false)
            service.isPanelExpanded = false
        case 4:
            // ⑤ 展开但完全不采样：若 CPU 仍高，说明面板在持续重绘（bug）；若降到地板，说明是每次更新重绘
            controller.forceState(.expanded, animated: false)
            service.isPanelExpanded = true
            service.stop()
        case 5:
            // ⑥ 恢复采样，并把温度/风扇切到高频（模拟用户正盯着温度看的场景）
            service.thermalIsVisible = true
            service.isPanelExpanded = true
            service.start()
        default:
            break
        }

        samplesAtStart = service.sampleCount
        cpuAtStart = SelfBenchmark.cpuSecondsAndRSS().cpu
        wallAtStart = Date()

        DispatchQueue.main.asyncAfter(deadline: .now() + phaseSeconds) {
            MainActor.assumeIsolated {
                self.report(title)
                self.index += 1
                self.next()
            }
        }
    }

    private func report(_ title: String) {
        let usage = SelfBenchmark.cpuSecondsAndRSS()
        let wall = Date().timeIntervalSince(wallAtStart)
        let cpuDelta = max(0, usage.cpu - cpuAtStart)
        let percent = wall > 0 ? cpuDelta / wall * 100 : 0
        let footprint = SelfBenchmark.physicalFootprint()
        print(String(format: "[bench] %@ %.1fs：平均 CPU %.3f%%（累计 %.1f ms）· 物理占用 %.1f MB · RSS %.1f MB · 采样 %d 次（平均 %.2f ms/次）",
                     title, wall, percent, cpuDelta * 1000,
                     Double(footprint) / 1_048_576, Double(usage.rss) / 1_048_576,
                     service.sampleCount - samplesAtStart, service.lastSampleMillis))
    }

    private func finish() {
        service.stop()
        print("[bench] 完成")
        exit(0)
    }
}
