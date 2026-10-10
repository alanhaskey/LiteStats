// 历史统计的磁盘格式：自定义紧凑二进制，不用 SQLite。
//
// 为什么不用 SQLite：
//   1. 零依赖 —— 系统 libsqlite3 需要 module map / 链接配置，CLT-only 环境下容易踩坑；
//   2. 写入模式极其简单（只追加 + 偶尔整体重写），用不上 SQL 的查询能力：
//      查询永远是"按时间区间扫一遍"，几百 KB 的定长记录扫一次是几十微秒级；
//   3. 崩溃安全容易做对 —— **定长记录 + 只追加**，写一半断电最多留一条残缺尾巴，
//      读的时候按 `(文件长度 - 头部) % 记录长度` 直接丢弃即可，不会"整库损坏"；
//      需要清理过期数据时写临时文件再 rename，是原子的。
//
// 文件布局（全部小端）：
//   偏移 0   魔数 'L''S''H''1'（4 字节 ASCII）
//   偏移 4   版本号 UInt32 = 1
//   偏移 8   单条记录字节数 UInt32（用于自检，防止代码改了结构却读旧文件）
//   偏移 12  保留 UInt32 = 0
//   偏移 16  之后是连续的定长记录，按时间升序追加
import Foundation

// MARK: - 记录类型

/// 分钟级记录（72 字节）。
///
/// `gpuSeconds` / `memoryByteSeconds` 存的是**对时间的积分**而不是平均：
/// 平均值的分母（覆盖秒数）在跨桶合并时会变，存积分才能无损地向上滚动合成小时 / 天。
struct MinuteRecord {
    static let byteCount = 72
    static let magic: [UInt8] = Array("LSM1".utf8)
    static let fileName = "minutes.bin"

    var start: Int64 = 0
    var cpuSeconds: Double = 0
    var gpuSeconds: Double = 0
    var memoryByteSeconds: Double = 0
    var networkIn: UInt64 = 0
    var networkOut: UInt64 = 0
    var coveredSeconds: Double = 0
    var temperatureMax: Double = .nan   // NaN 表示整分钟都没有温度数据
    var sampleCount: Int32 = 0

    func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.byteCount)
        bytes.appendI64(start)
        bytes.appendDouble(cpuSeconds)
        bytes.appendDouble(gpuSeconds)
        bytes.appendDouble(memoryByteSeconds)
        bytes.appendU64(networkIn)
        bytes.appendU64(networkOut)
        bytes.appendDouble(coveredSeconds)
        bytes.appendDouble(temperatureMax)
        bytes.appendI32(sampleCount)
        bytes.appendI32(0)                      // 保留
        return bytes
    }

    init() {}

    init?(raw: UnsafeRawBufferPointer, offset: Int) {
        guard offset + Self.byteCount <= raw.count else { return nil }
        start = raw.loadI64(offset)
        cpuSeconds = raw.loadDouble(offset + 8)
        gpuSeconds = raw.loadDouble(offset + 16)
        memoryByteSeconds = raw.loadDouble(offset + 24)
        networkIn = raw.loadU64(offset + 32)
        networkOut = raw.loadU64(offset + 40)
        coveredSeconds = raw.loadDouble(offset + 48)
        temperatureMax = raw.loadDouble(offset + 56)
        sampleCount = raw.loadI32(offset + 64)
    }

    /// 把同一桶的另一条记录并进来（见 HistoryStore 里"重复 start 合并"的说明）。
    mutating func merge(_ other: MinuteRecord) {
        cpuSeconds += other.cpuSeconds
        gpuSeconds += other.gpuSeconds
        memoryByteSeconds += other.memoryByteSeconds
        networkIn &+= other.networkIn
        networkOut &+= other.networkOut
        coveredSeconds += other.coveredSeconds
        sampleCount &+= other.sampleCount
        if other.temperatureMax.isFinite {
            temperatureMax = temperatureMax.isFinite ? max(temperatureMax, other.temperatureMax)
                                                     : other.temperatureMax
        }
    }
}

/// 小时 / 天共用的一种记录（64 字节）。两者需要的字段完全一样，只是 `start` 的粒度不同。
struct BucketRecord {
    static let byteCount = 64
    static let hourMagic: [UInt8] = Array("LSH1".utf8)
    static let dayMagic: [UInt8] = Array("LSD1".utf8)
    static let hourFileName = "hours.bin"
    static let dayFileName = "days.bin"

    var start: Int64 = 0
    var cpuSeconds: Double = 0
    var gpuSeconds: Double = 0
    var memoryByteSeconds: Double = 0
    var networkIn: UInt64 = 0
    var networkOut: UInt64 = 0
    var coveredSeconds: Double = 0
    var sampleCount: Int32 = 0

    func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.byteCount)
        bytes.appendI64(start)
        bytes.appendDouble(cpuSeconds)
        bytes.appendDouble(gpuSeconds)
        bytes.appendDouble(memoryByteSeconds)
        bytes.appendU64(networkIn)
        bytes.appendU64(networkOut)
        bytes.appendDouble(coveredSeconds)
        bytes.appendI32(sampleCount)
        bytes.appendI32(0)                      // 保留
        return bytes
    }

    init() {}

    init?(raw: UnsafeRawBufferPointer, offset: Int) {
        guard offset + Self.byteCount <= raw.count else { return nil }
        start = raw.loadI64(offset)
        cpuSeconds = raw.loadDouble(offset + 8)
        gpuSeconds = raw.loadDouble(offset + 16)
        memoryByteSeconds = raw.loadDouble(offset + 24)
        networkIn = raw.loadU64(offset + 32)
        networkOut = raw.loadU64(offset + 40)
        coveredSeconds = raw.loadDouble(offset + 48)
        sampleCount = raw.loadI32(offset + 56)
    }

    mutating func merge(_ other: BucketRecord) {
        cpuSeconds += other.cpuSeconds
        gpuSeconds += other.gpuSeconds
        memoryByteSeconds += other.memoryByteSeconds
        networkIn &+= other.networkIn
        networkOut &+= other.networkOut
        coveredSeconds += other.coveredSeconds
        sampleCount &+= other.sampleCount
    }
}

/// 按应用 + 时间桶（小时或天）的记录（128 字节）。
/// 应用名直接内联在记录里（定长 72 字节 UTF-8），省掉一次间接寻址；
/// 路径不进这里（太长），单独放 `app-names.bin` 的 name → path 表。
struct AppBucketRecord {
    static let byteCount = 128
    static let nameCapacity = 72
    static let hourMagic: [UInt8] = Array("LSA1".utf8)
    static let dayMagic: [UInt8] = Array("LSA2".utf8)
    static let hourFileName = "app-hours.bin"
    static let dayFileName = "app-days.bin"

    var bucketStart: Int64 = 0
    var cpuSeconds: Double = 0
    var networkIn: UInt64 = 0
    var networkOut: UInt64 = 0
    var peakMemoryBytes: UInt64 = 0
    var sampleCount: Int32 = 0
    /// UTF-8 字节（长度 <= nameCapacity），解码时用 String(decoding:as:) 容错
    var nameBytes: [UInt8] = Array(repeating: 0, count: AppBucketRecord.nameCapacity)

    /// 把名字截断到 `nameCapacity` 字节，且**不劈开多字节 UTF-8 字符**（否则解码出 U+FFFD）。
    static func truncatedNameBytes(_ name: String) -> [UInt8] {
        var bytes = Array(name.utf8.prefix(nameCapacity))
        while !bytes.isEmpty {
            let lead = bytes[bytes.count - 1]
            if lead & 0x80 == 0 { break }                       // ASCII：本身就是完整字符
            var continuation = 0
            var index = bytes.count - 1
            while index >= 0, bytes[index] & 0xC0 == 0x80 {     // 往前数续字节 10xxxxxx
                continuation += 1
                index -= 1
            }
            if index < 0 { bytes.removeAll(); break }           // 整段都是续字节（不该发生）
            let leadByte = bytes[index]
            let expected: Int
            if leadByte & 0xF8 == 0xF0 { expected = 4 }
            else if leadByte & 0xF0 == 0xE0 { expected = 3 }
            else if leadByte & 0xE0 == 0xC0 { expected = 2 }
            else { expected = 1 }
            if continuation + 1 == expected { break }           // 尾部字符完整
            bytes.removeLast(continuation + 1)                  // 去掉残缺字符，继续检查前一个
        }
        var padded = bytes
        padded.append(contentsOf: [UInt8](repeating: 0, count: nameCapacity - bytes.count))
        return padded
    }

    var name: String {
        var length = 0
        while length < nameBytes.count, nameBytes[length] != 0 { length += 1 }
        return String(decoding: nameBytes[0..<length], as: UTF8.self)
    }

    func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.byteCount)
        bytes.appendI64(bucketStart)
        bytes.appendDouble(cpuSeconds)
        bytes.appendU64(networkIn)
        bytes.appendU64(networkOut)
        bytes.appendU64(peakMemoryBytes)
        bytes.appendI32(sampleCount)
        bytes.appendI32(Int32(nameBytes.count))
        bytes.append(contentsOf: nameBytes)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))   // 保留 / 对齐
        return bytes
    }

    init() {}

    init?(raw: UnsafeRawBufferPointer, offset: Int) {
        guard offset + Self.byteCount <= raw.count else { return nil }
        bucketStart = raw.loadI64(offset)
        cpuSeconds = raw.loadDouble(offset + 8)
        networkIn = raw.loadU64(offset + 16)
        networkOut = raw.loadU64(offset + 24)
        peakMemoryBytes = raw.loadU64(offset + 32)
        sampleCount = raw.loadI32(offset + 40)
        var name = [UInt8](repeating: 0, count: Self.nameCapacity)
        for index in 0..<Self.nameCapacity {
            name[index] = raw.loadUInt8(offset + 48 + index)
        }
        nameBytes = name
    }

    mutating func merge(_ other: AppBucketRecord) {
        cpuSeconds += other.cpuSeconds
        networkIn &+= other.networkIn
        networkOut &+= other.networkOut
        peakMemoryBytes = max(peakMemoryBytes, other.peakMemoryBytes)
        sampleCount &+= other.sampleCount
    }
}

// MARK: - 定长记录文件编解码

enum HistoryFileCodec {
    static let headerSize = 16
    static let version: UInt32 = 1

    /// 组装一个完整的文件内容（头部 + 全部记录）。用于首次创建与压缩重写。
    static func encode<T>(_ records: [T], magic: [UInt8], recordSize: Int,
                          encodeRecord: (T) -> [UInt8]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerSize + records.count * recordSize)
        bytes.append(contentsOf: magic)
        bytes.appendU32(version)
        bytes.appendU32(UInt32(recordSize))
        bytes.appendU32(0)
        for record in records {
            bytes.append(contentsOf: encodeRecord(record))
        }
        return Data(bytes)
    }

    /// 只把记录拼成一段（不含头部），用于追加写。
    static func encodeRecords<T>(_ records: [T], encodeRecord: (T) -> [UInt8]) -> Data {
        var bytes = [UInt8]()
        for record in records {
            bytes.append(contentsOf: encodeRecord(record))
        }
        return Data(bytes)
    }

    /// 读文件。返回 nil 表示"文件不存在"（正常情况）；
    /// 抛错表示文件存在但头不对（结构变了 / 被别的东西占用）。
    static func load<T>(_ url: URL, magic: [UInt8], recordSize: Int,
                        decode: (UnsafeRawBufferPointer, Int) -> T?) throws -> [T]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.count >= headerSize else { return [] }
        return try data.withUnsafeBytes { raw -> [T] in
            guard raw.count >= headerSize else { return [] }
            let fileMagic = Array(raw[0..<4])
            let fileVersion = raw.loadU32(4)
            let fileRecordSize = Int(raw.loadU32(8))
            guard fileMagic == magic, fileVersion == version, fileRecordSize == recordSize else {
                throw HistoryStorageError.formatMismatch(url.lastPathComponent)
            }
            var records: [T] = []
            records.reserveCapacity(max(0, (raw.count - headerSize) / recordSize))
            var offset = headerSize
            // 尾部不足一条记录 → 上次写入被中断留下的残片，直接忽略。
            while offset + recordSize <= raw.count {
                if let record = decode(raw, offset) { records.append(record) }
                offset += recordSize
            }
            return records
        }
    }
}

/// 应用名 → 可执行路径 的旁表（变长记录，只追加，后写的覆盖先写的）。
///
/// 之所以单独放一张表：路径很长（可能 200+ 字节），塞进 128 字节的定长桶记录里会撑爆格式；
/// 而一个名字的路径基本不变，全表通常只有几百行、几十 KB。
enum AppNameTable {
    static let magic: [UInt8] = Array("LSN1".utf8)
    static let fileName = "app-names.bin"

    static func encode(name: String, path: String?) -> Data {
        let nameBytes = Array(name.utf8)
        var pathBytes = Array((path ?? "").utf8)
        if pathBytes.count > 1024 { pathBytes = Array(pathBytes.prefix(1024)) }
        var bytes = [UInt8]()
        bytes.reserveCapacity(8 + nameBytes.count + pathBytes.count)
        bytes.appendU32(UInt32(nameBytes.count))
        bytes.appendU32(UInt32(pathBytes.count))
        bytes.append(contentsOf: nameBytes)
        bytes.append(contentsOf: pathBytes)
        return Data(bytes)
    }

    /// 读取 name → path 映射；后出现的条目覆盖先出现的。
    static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        var result: [String: String] = [:]
        data.withUnsafeBytes { raw in
            var offset = 0
            // 这张表也是走 HistoryStore.append 写的，所以文件开头有 16 字节的通用头；
            // 认一下魔数再跳过（兼容没有头的裸文件）。
            if raw.count >= HistoryFileCodec.headerSize, Array(raw[0..<4]) == magic {
                offset = HistoryFileCodec.headerSize
            }
            while offset + 8 <= raw.count {
                let nameLength = Int(raw.loadU32(offset))
                let pathLength = Int(raw.loadU32(offset + 4))
                let start = offset + 8
                guard nameLength >= 0, pathLength >= 0,
                      start + nameLength + pathLength <= raw.count else { break }
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<(start + nameLength)]),
                                  as: UTF8.self)
                if pathLength > 0 {
                    let path = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(start + nameLength)..<(start + nameLength + pathLength)]),
                                      as: UTF8.self)
                    if !name.isEmpty { result[name] = path }
                }
                offset = start + nameLength + pathLength
            }
        }
        return result
    }
}

enum HistoryStorageError: Error, CustomStringConvertible {
    case formatMismatch(String)
    case fileSystem(String)

    var description: String {
        switch self {
        case .formatMismatch(let name):
            return "历史文件 \(name) 头部不匹配（版本 / 记录长度变了），已按空文件处理"
        case .fileSystem(let message):
            return "历史文件读写失败：\(message)"
        }
    }
}

// MARK: - 字节读写小工具

extension Array where Element == UInt8 {
    @inline(__always) mutating func appendU32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    @inline(__always) mutating func appendI32(_ value: Int32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    @inline(__always) mutating func appendU64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    @inline(__always) mutating func appendI64(_ value: Int64) {
        appendU64(UInt64(bitPattern: value))
    }
    @inline(__always) mutating func appendDouble(_ value: Double) {
        appendU64(value.bitPattern)
    }
}

extension UnsafeRawBufferPointer {
    @inline(__always) func loadUInt8(_ offset: Int) -> UInt8 { self[offset] }
    @inline(__always) func loadU32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
    @inline(__always) func loadI32(_ offset: Int) -> Int32 {
        Int32(littleEndian: loadUnaligned(fromByteOffset: offset, as: Int32.self))
    }
    @inline(__always) func loadU64(_ offset: Int) -> UInt64 {
        UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
    @inline(__always) func loadI64(_ offset: Int) -> Int64 {
        Int64(bitPattern: loadU64(offset))
    }
    @inline(__always) func loadDouble(_ offset: Int) -> Double {
        Double(bitPattern: loadU64(offset))
    }
}


