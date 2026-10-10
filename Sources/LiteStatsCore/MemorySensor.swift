// 内存传感器：host_statistics64(HOST_VM_INFO64) + sysctl(vm.swapusage)。
import Darwin
import Foundation

final class MemorySensor {
    private let host: host_t
    /// 页大小：Apple Silicon 是 16 KiB，Intel 是 4 KiB。取一次即可（不会变）。
    private let pageSize: UInt64

    private var lastGood: MemoryStats?

    init() {
        host = mach_host_self()

        var size: vm_size_t = 0
        if host_page_size(host, &size) == KERN_SUCCESS, size > 0 {
            pageSize = UInt64(size)
        } else {
            // 兜底：sysctl hw.pagesize（与 vm_kernel_page_size 同值），再不行按 Apple Silicon 的 16 KiB。
            var fallback: UInt64 = 0
            var size = MemoryLayout<UInt64>.stride
            let ok = sysctlbyname("hw.pagesize", &fallback, &size, nil, 0) == 0
            pageSize = (ok && fallback > 0) ? fallback : 16384
        }
    }

    deinit {
        mach_port_deallocate(mach_task_self_, host)
    }

    /// 采一拍内存。永不抛错：失败时返回上一次的良好值，从未成功过则返回全 0。
    func sample() -> MemoryStats {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return lastGood ?? .empty }

        let page = pageSize
        let active = UInt64(vmStats.active_count) * page
        let inactive = UInt64(vmStats.inactive_count) * page
        let wired = UInt64(vmStats.wire_count) * page
        // 压缩内存：压缩器**实际占用**的物理页（不是压缩前的逻辑大小）。
        let compressed = UInt64(vmStats.compressor_page_count) * page
        // free_count 是"干净可分配页"，speculative 是预读页（随时可回收），
        // 二者相加才接近 Activity Monitor 的"已缓存文件/可用"口径。
        let free = (UInt64(vmStats.free_count) + UInt64(vmStats.speculative_count)) * page
        // 可回收文件缓存：file-backed 页（external）减去可清除页（purgeable）。
        let external = UInt64(vmStats.external_page_count) * page
        let purgeable = UInt64(vmStats.purgeable_count) * page
        let cached = external > purgeable ? external - purgeable : 0

        let total = ProcessInfo.processInfo.physicalMemory
        // 口径与契约一致：used = active + wired + compressed。
        // 夹一刀防止异常情况下 used > total 导致 usage > 1（UI 会画歪）。
        let rawUsed = active &+ wired &+ compressed
        let used = total > 0 ? min(rawUsed, total) : rawUsed

        let (swapTotal, swapUsed) = Self.swapUsage()

        let stats = MemoryStats(total: total, used: used, free: free,
                                active: active, inactive: inactive, wired: wired,
                                compressed: compressed, cached: cached,
                                swapTotal: swapTotal, swapUsed: swapUsed)
        lastGood = stats
        return stats
    }

    /// `sysctl vm.swapusage` → `struct xsw_usage`。
    /// 坑：字段是 64 位字节数（不是页数），且 sysctl 返回的 oldlen 必须传对，
    /// 否则会读到半截结构体。
    private static func swapUsage() -> (total: UInt64, used: UInt64) {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let ok = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        guard ok, size == MemoryLayout<xsw_usage>.stride else { return (0, 0) }
        return (swap.xsu_total, swap.xsu_used)
    }
}
