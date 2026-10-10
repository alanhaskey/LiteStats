// 磁盘传感器：statfs("/")。
import Darwin
import Foundation

final class DiskSensor {
    private let path: String

    init(path: String = "/") {
        self.path = path
    }

    /// 采一拍磁盘占用；失败返回 nil（上层 `disk` 就是 nil，不抛错）。
    ///
    /// 坑：`f_bsize` 是"基本块大小"（APFS 上 4096），不是 `f_iosize`（最优 IO 大小）；
    /// 容量换算必须用 f_bsize。
    /// 坑：`f_bfree` 是包含 root 保留块的剩余块数，`f_bavail` 才是**普通用户可用**的
    /// 剩余块数。UI 上展示"可用空间"应该用 f_bavail（与 Finder/df 的口径一致）。
    func sample() -> DiskStats? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }

        let blockSize = UInt64(fs.f_bsize)
        guard blockSize > 0 else { return nil }

        let total = UInt64(fs.f_blocks) &* blockSize
        let free = UInt64(fs.f_bavail) &* blockSize
        guard total > 0 else { return nil }
        let used = total > free ? total - free : 0

        return DiskStats(total: total, free: free, used: used)
    }
}
