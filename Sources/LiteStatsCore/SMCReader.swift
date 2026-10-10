// 风扇 / SMC 温度：AppleSMC 用户态客户端（实测**不需要 root**）。
//
// ## 坑 1：结构体必须是精确 80 字节
// AppleSMC 的 selector 2（kSMCUserClientOpen 之外的 IOConnectCallStructMethod 索引）要求
// input/output 结构体 80 字节。C 头文件里 `dataSize(4) dataType(4) attrs(1)` 之后编译器会
// 插入 3 字节 padding，Swift 里如果不把这 3 个 pad 显式写出来，后面的
// result/status/data8/data32/bytes 会整体前移，stride 变成 76，selector 2 直接返回
// `0xe00002c2 (kIOReturnBadArgument)`。实测 stride == 80 才成功（SMCKeyData 里有断言用的
// `Layout` 常量，单测也会检查）。
//
// ## 坑 2：字节序不是统一的
// 实测本机 AppleSMC：
//   * `flt `（风扇转速 / 电池温度）= IEEE754 位模式，按**主机字节序（小端）**存放：
//     F0Ac = 00 E0 10 45 → `load(as: Float.self)` = 2318.0。
//   * `ui8 ` / `ui16` / `ui32` = **大端**整数：#KEY = 00 00 0E 1B → 3611。
//   所以解析必须按 dataType 分派，不能一律 `load(as:)`，也不能一律手动倒序。
//
// ## 坑 3：键不存在不是错误
// 本机 `TC0P` / `Tp01` / `Tp09` 的 dataSize == 0（键在表里但没有数据），
// 这是正常情况，不能当失败处理；风扇也是用 `F{i}Ac` 是否存在来探测的。
import Foundation
import IOKit

// MARK: - AppleSMC 数据结构（80 字节，布局不可改）

struct SMCKeyData {
    var key: UInt32 = 0
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    var dataSize: UInt32 = 0, dataType: UInt32 = 0
    /// ⚠️ 这 3 个 pad 不能省：省掉后 stride 变成 76，selector 2 报 kIOReturnBadArgument。
    var attrs: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    /// 实测 80；单测里会断言（防止有人"顺手清理"那 3 个 pad）。
    static let layoutStride = 80
}

// MARK: - 字节解析（纯函数，可单测）

enum SMCValueParser {
    /// `flt `：4 字节 IEEE754 位模式，按主机字节序（小端）读取。
    /// 实测 F0Ac = [0x00, 0xE0, 0x10, 0x45] → 2318.0 rpm。
    static func float(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        let raw = Array(bytes.prefix(4))
        return Double(raw.withUnsafeBytes { $0.load(as: Float.self) })
    }

    /// ui8 / ui16 / ui32：大端无符号整数。
    /// 实测 #KEY = [0x00, 0x00, 0x0E, 0x1B] → 3611（小端解释会得到 453902336）。
    static func unsigned(_ bytes: [UInt8]) -> Double? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        var value: UInt64 = 0
        for byte in bytes { value = (value << 8) | UInt64(byte) }
        return Double(value)
    }

    /// fpe2：大端 16 位定点，低 2 位是小数（Intel Mac 的风扇转速键）。本机是 `flt `，用不到。
    static func fixedPoint14_2(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    /// sp78：大端 16 位**有符号**定点，小数 8 位（Intel Mac 的温度键）。本机用不到。
    static func signedFixedPoint8_8(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    /// 按 SMC dataType 分派。未知类型返回 nil（绝不猜）。
    static func number(bytes: [UInt8], size: UInt32, type: String) -> Double? {
        guard size > 0, Int(size) <= bytes.count else { return nil }
        switch type.trimmingCharacters(in: .whitespaces) {
        case "flt": return float(bytes)
        case "ui8", "ui16", "ui32", "ui64": return unsigned(bytes)
        case "fpe2": return fixedPoint14_2(bytes)
        case "sp78": return signedFixedPoint8_8(bytes)
        default: return nil
        }
    }
}

/// 一个 SMC 键的原始读值。
struct SMCValue: Equatable {
    let key: String
    let size: UInt32
    let type: String
    let bytes: [UInt8]

    /// 解析成数值；无法解析时为 nil。
    var number: Double? { SMCValueParser.number(bytes: bytes, size: size, type: type) }
}

// MARK: - 客户端

/// 线程安全：只在 `SystemMonitor` 的锁内使用，自身不加锁。
final class SMCReader {
    /// kSMCUserClientMethodReadKeyInfo / ReadKey / ReadIndex（AppleSMC 用户客户端的 selector 固定为 2）
    private static let kernelSelector: UInt32 = 2
    private static let commandReadKey: UInt8 = 5
    private static let commandReadIndex: UInt8 = 8
    private static let commandReadKeyInfo: UInt8 = 9

    /// 风扇与温度键的上限：防御性上限，避免损坏的键表导致死循环。
    static let maxFans = 8
    /// flt 的最大字节数（SMCKeyData.bytes 是 32 字节）。
    private static let maxValueSize: UInt32 = 32

    private let serviceName: String
    private var connection: io_connect_t = 0

    /// 键元数据缓存（dataSize / dataType 不会变）：省掉每次读键都要先发的 getKeyInfo 调用，
    /// 实测把 2 个风扇 8 个键的读取从 ~2ms 降到 ~1ms。nil 表示"这个键不存在"（同样值得缓存，
    /// 例如探测 F2Ac 时不用每次重试）。
    private var keyInfoCache: [String: (size: UInt32, type: String)?] = [:]

    /// 打开失败的退避（照抄 GPUSensor）。
    private var lastLookupTick = Int.min
    private let lookupRetryTicks = 10

    /// 测试可以传一个不存在的服务名来验证降级路径。
    init(serviceName: String = "AppleSMC") {
        self.serviceName = serviceName
    }

    deinit { close() }

    var isAvailable: Bool { connection != 0 }

    /// 确保连接可用（带失败退避）。`tick` 是调用方的单调递增计数。
    func ensureOpen(tick: Int) -> Bool {
        if connection != 0 { return true }
        if lastLookupTick != Int.min, tick - lastLookupTick < lookupRetryTicks { return false }
        lastLookupTick = tick
        return open()
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        keyInfoCache.removeAll(keepingCapacity: true)
    }

    // MARK: - 读键

    /// 读一个键（getKeyInfo → readKey）。键不存在（dataSize == 0）或读失败时返回 nil。
    func value(_ key: String) -> SMCValue? {
        guard connection != 0, let info = keyInfo(key) else { return nil }

        var input = SMCKeyData()
        input.key = Self.fourCC(key)
        input.data8 = Self.commandReadKey
        input.dataSize = info.size
        guard let output = call(&input), output.result == 0 else { return nil }

        let all = withUnsafeBytes(of: output.bytes) { Array($0) }
        return SMCValue(key: key, size: info.size, type: info.type,
                        bytes: Array(all.prefix(Int(info.size))))
    }

    private func keyInfo(_ key: String) -> (size: UInt32, type: String)? {
        if let cached = keyInfoCache[key] { return cached }
        let info = readKeyInfo(key)
        keyInfoCache[key] = info
        return info
    }

    private func readKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        var input = SMCKeyData()
        input.key = Self.fourCC(key)
        input.data8 = Self.commandReadKeyInfo
        guard let output = call(&input), output.result == 0 else { return nil }
        // 键存在但没有数据（本机 TC0P / Tp01 / Tp09）→ 视为不可读，不是错误。
        guard output.dataSize > 0, output.dataSize <= Self.maxValueSize else { return nil }
        return (output.dataSize, Self.fourCCString(output.dataType))
    }

    /// 枚举第 index 个键名（仅探索用，正式路径不依赖它）。
    func keyName(at index: UInt32) -> String? {
        guard connection != 0 else { return nil }
        var input = SMCKeyData()
        input.data8 = Self.commandReadIndex
        input.data32 = index
        guard let output = call(&input), output.result == 0, output.key != 0 else { return nil }
        return Self.fourCCString(output.key)
    }

    // MARK: - 风扇

    /// 探测并读取全部风扇：`F{i}Ac` 存在就算一个风扇，读不到就停止（i 从 0 递增）。
    /// 转速/上下限/目标值都是可选的（某些机型没有 F{i}Tg）。
    func fanReadings() -> [FanReading] {
        guard connection != 0 else { return [] }
        var fans: [FanReading] = []
        for index in 0..<Self.maxFans {
            let prefix = "F\(index)"
            // 存在性探测：F{i}Ac 读不出来就认为没有第 i 个风扇。
            guard let actual = value("\(prefix)Ac") else { break }
            fans.append(FanReading(index: index,
                                   rpm: Self.saneRPM(actual.number),
                                   minRPM: Self.saneRPM(value("\(prefix)Mn")?.number),
                                   maxRPM: Self.saneRPM(value("\(prefix)Mx")?.number),
                                   targetRPM: Self.saneRPM(value("\(prefix)Tg")?.number)))
        }
        return fans
    }

    /// 转速合理性：0 是合法的（风扇停转），负数和 > 30000 rpm 是垃圾值 → nil。
    private static func saneRPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 30000 else { return nil }
        return value
    }

    // MARK: - 温度兜底

    /// HID 完全读不出时的兜底温度键（都是电池/机身温度）；本机 TB0T / Ts0P 可读。
    static let fallbackTemperatureKeys = ["TB0T", "Ts0P"]

    /// 读兜底温度键；键不存在时静默跳过。
    func fallbackTemperatures() -> [RawThermalReading] {
        guard connection != 0 else { return [] }
        var readings: [RawThermalReading] = []
        for key in Self.fallbackTemperatureKeys {
            guard let value = value(key), let number = value.number else { continue }
            readings.append(RawThermalReading(name: key, celsius: number))
        }
        return readings
    }

    // MARK: - 私有

    private func open() -> Bool {
        // IOServiceMatching 返回 +1 的字典，所有权移交给 IOServiceGetMatchingService。
        guard let matching = IOServiceMatching(serviceName) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        var newConnection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &newConnection) == KERN_SUCCESS,
              newConnection != 0 else {
            return false
        }
        connection = newConnection
        return true
    }

    /// 调一次 AppleSMC 用户客户端方法（selector 2）。失败返回 nil。
    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outputSize = SMCKeyData.layoutStride
        let result = IOConnectCallStructMethod(connection, Self.kernelSelector,
                                              &input, SMCKeyData.layoutStride,
                                              &output, &outputSize)
        guard result == KERN_SUCCESS else { return nil }
        return output
    }

    /// "F0Ac" → 四字符 UInt32（大端打包，和 SMC 的键表示一致）。
    private static func fourCC(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    /// UInt32 → "ui32" / "flt " 这样的四字符类型串。
    private static func fourCCString(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                     UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
