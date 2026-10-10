// 网络传感器：getifaddrs 枚举接口 + IFMIB sysctl 读 64 位累计计数。
//
// 坑（实测，macOS 27.0.1 / 26A434，Apple M5 Pro）：
// 1) `getifaddrs` 的 AF_LINK 项里 `ifa_data` 指向 `struct if_data`，其
//    `ifi_ibytes/ifi_obytes` 是 **32 位**且被内核截断（与 netstat 的值相差
//    整数倍 2^32：实测 en0 netstat=23542993737，if_data=2047927296）。
//    所以累计字节数不能用它（会丢掉高位）。
// 2) 正确来源是 sysctl IFMIB：MIB = {CTL_NET, PF_LINK, 0, IFMIB_IFDATA, ifindex,
//    IFDATA_GENERAL} → `struct ifmibdata`，其中 `ifmd_data` 是 `struct if_data64`，
//    拿到的是**真正的 64 位累计值**（实测与 `netstat -ib` 逐字节一致）。
//    注意 MIB 第 4 个元素是 IFMIB_IFDATA(=2)，不要再插一个 0，否则 ENOENT。
// 3) 只统计"主接口"（SCDynamicStore 的 State:/Network/Global/IPv4 → PrimaryInterface），
//    否则 utun/bridge/vmenet/anpi 会把同一份流量重复计数。
import Darwin
import Foundation
import SystemConfiguration

/// 一次 getifaddrs 枚举出来的接口信息。
struct InterfaceInfo {
    var index: UInt32
    var name: String
    /// 32 位回退口径的累计字节（仅当 IFMIB 不可用时使用）
    var rawReceived: UInt64
    var rawSent: UInt64
    /// IFF_UP && IFF_RUNNING
    var isUp: Bool
    var isLoopback: Bool
    /// 是否已配置 IPv4/IPv6 地址（用来判断"真的连通"而不只是网卡 up）
    var hasAddress: Bool
}

/// 计数器来源；两个来源之间不能直接做差（量纲不同），切换时这一拍速率为 0。
enum CounterSource {
    case ifmib       // 64 位真值
    case ifaddrs32   // 32 位回退，需回绕补偿
}

final class NetworkSensor {
    /// 主接口缓存 TTL（秒）：SCDynamicStore 查询走 configd IPC，不必每拍都做。
    private let primaryTTL: TimeInterval = 2

    private var store: SCDynamicStore?
    private var cachedPrimary: String?
    private var lastPrimaryLookup: TimeInterval = -.greatestFiniteMagnitude

    // 增量状态（被 SystemMonitor 的锁保护）
    private var previousName: String?
    private var previousReceived: UInt64 = 0
    private var previousSent: UInt64 = 0
    private var previousTime: TimeInterval?
    private var previousSource: CounterSource?

    // 32 位回绕补偿（只有 ifaddrs32 回退路径需要）
    private var lastRawReceived: UInt64 = 0
    private var lastRawSent: UInt64 = 0
    private var wrapOffset: UInt64 = 0

    /// 采一拍。`now` 是单调时钟秒数（调用方提供），用于算速率间隔。
    func sample(now: TimeInterval) -> NetworkStats {
        let interfaces = Self.readInterfaces()
        guard !interfaces.isEmpty else {
            // 完全枚举不到接口：返回上次的累计值 + 0 速率，不抛错。
            return NetworkStats(download: 0, upload: 0,
                                received: previousReceived, sent: previousSent,
                                interfaceName: previousName, isConnected: false)
        }

        let primary = resolvePrimaryInterface(now: now)
        guard let chosen = chooseInterface(from: interfaces, primary: primary) else {
            return NetworkStats(download: 0, upload: 0,
                                received: previousReceived, sent: previousSent,
                                interfaceName: previousName, isConnected: false)
        }

        // 优先 IFMIB 的 64 位真值，失败再退回 getifaddrs 的 32 位计数。
        let source: CounterSource
        let received: UInt64
        let sent: UInt64
        if let counters = Self.read64BitCounters(index: chosen.index) {
            source = .ifmib
            received = counters.received
            sent = counters.sent
        } else {
            source = .ifaddrs32
            // 32 位计数器会回绕：一旦变小就认为回绕了一次，补 2^32。
            if chosen.rawReceived < lastRawReceived { wrapOffset &+= (1 << 32) }
            lastRawReceived = chosen.rawReceived
            lastRawSent = chosen.rawSent
            received = wrapOffset &+ chosen.rawReceived
            sent = wrapOffset &+ chosen.rawSent
        }

        let interval = previousTime.map { now - $0 } ?? 0
        let sameTarget = (previousName == chosen.name) && (previousSource == source) && interval > 0
        let download = sameTarget
            ? NetworkRateMath.bytesPerSecond(previous: previousReceived, current: received, interval: interval)
            : 0
        let upload = sameTarget
            ? NetworkRateMath.bytesPerSecond(previous: previousSent, current: sent, interval: interval)
            : 0

        previousName = chosen.name
        previousReceived = received
        previousSent = sent
        previousTime = now
        previousSource = source

        return NetworkStats(download: download, upload: upload,
                            received: received, sent: sent,
                            interfaceName: chosen.name,
                            isConnected: chosen.isUp && chosen.hasAddress)
    }

    /// 清空增量状态：下一拍只建立基线（速率为 0）。
    func reset() {
        previousName = nil
        previousReceived = 0
        previousSent = 0
        previousTime = nil
        previousSource = nil
        lastRawReceived = 0
        lastRawSent = 0
        wrapOffset = 0
        // 主接口缓存也一起失效，force refresh 一次。
        lastPrimaryLookup = -.greatestFiniteMagnitude
    }

    // MARK: - 接口选择

    private func chooseInterface(from interfaces: [InterfaceInfo], primary: String?) -> InterfaceInfo? {
        // 1) 主接口（SCDynamicStore）
        if let primary, let match = interfaces.first(where: { $0.name == primary && !$0.isLoopback }) {
            return match
        }
        // 2) en0
        if let match = interfaces.first(where: { $0.name == "en0" && !$0.isLoopback }) {
            return match
        }
        // 3) 任意 en*（优先已 up 且有地址、流量最大的那个）
        let candidates = interfaces.filter { $0.name.hasPrefix("en") && !$0.isLoopback }
        if let best = candidates.max(by: { ($0.rawReceived &+ $0.rawSent) < ($1.rawReceived &+ $1.rawSent) }) {
            return best
        }
        // 4) 兜底：任意非 loopback 且已 up 的接口
        return interfaces.first { !$0.isLoopback && $0.isUp }
    }

    /// 读 `State:/Network/Global/IPv4` 的 PrimaryInterface，带 TTL 缓存。
    private func resolvePrimaryInterface(now: TimeInterval) -> String? {
        if now - lastPrimaryLookup < primaryTTL { return cachedPrimary }
        lastPrimaryLookup = now

        if store == nil {
            // 只读用途：不需要 run loop source（我们不做变更通知）。
            store = SCDynamicStoreCreate(nil, "LiteStats" as CFString, nil, nil)
        }
        guard let store else { return cachedPrimary }
        let key = "State:/Network/Global/IPv4" as CFString
        guard let value = SCDynamicStoreCopyValue(store, key) as? [String: Any],
              let name = value["PrimaryInterface"] as? String, !name.isEmpty else {
            cachedPrimary = nil
            return nil
        }
        cachedPrimary = name
        return name
    }

    // MARK: - 底层读取

    /// getifaddrs 枚举（AF_LINK 项带计数与 flags，别的地址族项只用来判断"有 IP"）。
    static func readInterfaces() -> [InterfaceInfo] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var order: [String] = []
        var table: [String: InterfaceInfo] = [:]

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            pointer = entry.ifa_next

            guard let namePointer = entry.ifa_name, let addr = entry.ifa_addr else { continue }
            let name = String(cString: namePointer)
            let family = Int32(addr.pointee.sa_family)
            let flags = Int32(entry.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            var info = table[name] ?? InterfaceInfo(index: 0, name: name,
                                                   rawReceived: 0, rawSent: 0,
                                                   isUp: isUp, isLoopback: isLoopback,
                                                   hasAddress: false)
            if table[name] == nil { order.append(name) }
            info.isUp = info.isUp || isUp
            info.hasAddress = info.hasAddress || family == AF_INET || family == AF_INET6

            if family == AF_LINK {
                // AF_LINK 的 `ifa_addr` 就是 sockaddr_dl，`sdl_index` 即接口索引。
                // 千万别用 if_nametoindex()：实测 28 个接口要 0.87 ms（每次都是系统调用），
                // 而 sdl_index 是现成的，免费。
                let link = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self).pointee
                info.index = UInt32(link.sdl_index)

                if let data = entry.ifa_data {
                    // 注意：这里是 32 位被截断的计数，仅作回退用（见文件头注释）。
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    info.rawReceived = UInt64(stats.ifi_ibytes)
                    info.rawSent = UInt64(stats.ifi_obytes)
                }
            }
            table[name] = info
        }

        return order.compactMap { table[$0] }
    }

    /// IFMIB 64 位累计计数。失败（老系统 / 权限 / 接口刚消失）返回 nil。
    static func read64BitCounters(index: UInt32) -> (received: UInt64, sent: UInt64)? {
        guard index != 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_LINK, 0, IFMIB_IFDATA, Int32(bitPattern: index), IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.stride
        guard sysctl(&mib, 6, &data, &size, nil, 0) == 0 else { return nil }
        return (data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes)
    }
}
