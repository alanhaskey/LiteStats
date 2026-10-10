// 按进程采样：libproc（CPU 时间 / 常驻内存）。
//
// 为什么用 libproc 而不是 `ps` / `top`：
//   * 不用起子进程、不用解析文本，直接走 XNU 的 proc_pid_rusage；
//   * 实测遍历本机全部 ~195 个进程只要 0.5 ms（成功 135 个），每 5 秒采一次完全无感；
//   * 不需要 root。
//
// 关于单位：`ri_user_time` / `ri_system_time` 是**纳秒**（不是微秒，也不是 tick），
// `ri_phys_footprint` 是字节（这是 Activity Monitor 里显示的"内存"口径，
// 比 ri_resident_size 更贴近用户直觉，压缩内存算它的一份）。
import Foundation

/// 单个进程的一次快照（累计值）。
struct ProcessCounters {
    let pid: Int32
    let name: String
    /// 累计 CPU 秒数（user + system）
    let cpuSeconds: Double
    /// 当前物理内存占用（字节）
    let memoryBytes: UInt64
    let path: String?
}

enum ProcessSampler {
    /// 一次最多枚举多少个进程。4000 对 macOS 来说绰绰有余（实测 195 个），
    /// 超出部分会被内核截断，不会越界写。
    private static let maxProcesses = 4096
    private static let nameBufferSize = 256
    private static let pathBufferSize = 4096

    /// 枚举全部进程并读取 CPU / 内存。取不到的进程直接跳过（进程可能刚好退出）。
    static func sample() -> [ProcessCounters] {
        var pids = [pid_t](repeating: 0, count: maxProcesses)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.size, pids.count)

        var result: [ProcessCounters] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var info = rusage_info_current()
            let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
                // proc_pid_rusage 的 buffer 参数是 `rusage_info_t *`（即 void **），
                // 但内核实际把它当成"写入 rusage_info_current 结构体的首地址"，
                // 所以这里要把结构体指针重新绑定成 `rusage_info_t?` 再取地址。
                let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
                return proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, raw)
            }
            guard status == 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: nameBufferSize)
            guard proc_name(pid, &nameBuffer, UInt32(nameBufferSize)) > 0 else { continue }
            let name = Self.string(from: nameBuffer)
            guard !name.isEmpty else { continue }

            var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
            let path: String?
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBufferSize)) > 0 {
                let value = Self.string(from: pathBuffer)
                path = value.isEmpty ? nil : value
            } else {
                path = nil
            }

            let seconds = (Double(info.ri_user_time) + Double(info.ri_system_time)) / 1_000_000_000
            result.append(ProcessCounters(pid: pid, name: name,
                                          cpuSeconds: seconds.isFinite ? seconds : 0,
                                          memoryBytes: info.ri_phys_footprint,
                                          path: path))
        }
        return result
    }

    /// CChar 缓冲（NUL 结尾）→ String。不用已废弃的 `String(cString:)`。
    private static func string(from buffer: [CChar]) -> String {
        var length = 0
        while length < buffer.count, buffer[length] != 0 { length += 1 }
        return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
