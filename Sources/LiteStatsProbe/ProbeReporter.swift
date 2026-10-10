// 探针输出：人类可读一行 / JSONL 一行 + 汇总行。
import Foundation
import LiteStatsCore

final class ProbeReporter {
    private let json: Bool
    private let timestampFormatter: ISO8601DateFormatter

    init(json: Bool) {
        self.json = json
        self.timestampFormatter = ISO8601DateFormatter()
        self.timestampFormatter.formatOptions = [.withInternetDateTime]
    }

    /// 配置横幅：始终写 stderr，保证 `--json` 时 stdout 是纯 JSONL。
    func emitHeader(options: ProbeOptions, coreCount: Int) {
        let mode = options.json ? "json" : "human"
        emitError("[probe] cores=\(coreCount) seconds=\(formatSeconds(options.seconds)) "
                  + "interval=\(formatSeconds(options.interval)) mode=\(mode)")
    }

    func emit(snapshot: SystemSnapshot, sampleMs: Double) {
        if json {
            print(jsonLine(snapshot: snapshot, sampleMs: sampleMs))
        } else {
            print(humanLine(snapshot: snapshot, sampleMs: sampleMs))
        }
    }

    /// 汇总行：human 模式写 stdout（与每拍输出同流），json 模式写 stderr（不污染 JSONL）。
    func emitSummary(_ line: String) {
        if json {
            emitError(line)
        } else {
            print(line)
        }
    }

    func emitError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - 人类可读

    private func humanLine(snapshot s: SystemSnapshot, sampleMs: Double) -> String {
        let cores = s.cpu.perCore.map { String(format: "%3.0f", $0 * 100) }.joined(separator: " ")
        let gpu = s.gpu.utilization.map { String(format: "%3.0f%%", $0 * 100) } ?? " n/a"
        let mem = String(format: "%@/%@ %4.1f%%",
                         formatBytes(Double(s.memory.used)), formatBytes(Double(s.memory.total)),
                         s.memory.usage * 100)
        let iface = s.network.interfaceName ?? "-"
        let net = String(format: "↓%@/s ↑%@/s %@",
                         formatBytes(s.network.download), formatBytes(s.network.upload), iface)
        let disk = s.disk.map { String(format: "%4.1f%%", $0.usage * 100) } ?? " n/a"
        return String(format: "#%02d %5.1f%% cpu[u%4.1f s%4.1f i%4.1f] load %.2f/%.2f/%.2f "
                      + "cores[%@] gpu %@ mem %@ net %@ disk %@ %@ %.2fms",
                      s.sampleIndex, s.cpu.total * 100, s.cpu.user * 100, s.cpu.system * 100,
                      s.cpu.idle * 100, s.cpu.load1, s.cpu.load5, s.cpu.load15,
                      cores, gpu, mem, net, disk, thermalSummary(s.thermal), sampleMs)
    }

    /// 温度 / 风扇的人类可读摘要：`温度 CPU 52.0°C(最高 tdie) 电池 34.9°C 风扇 2317/2502rpm`
    /// 完全取不到时整段是 `温度 n/a 风扇 n/a`（不会显示 0，也不会打印 -9201°C 这种垃圾）。
    private func thermalSummary(_ thermal: ThermalStats) -> String {
        guard thermal.sourceDescription != nil else { return "温度 n/a 风扇 n/a" }

        var pieces: [String] = []
        pieces.append(thermal.cpuTemperature.map { String(format: "CPU %.1f°C(最高 tdie)", $0) }
                      ?? "CPU n/a")
        if let gpu = thermal.gpuTemperature {
            pieces.append(String(format: "GPU %.1f°C", gpu))
        }
        pieces.append(thermal.batteryTemperature.map { String(format: "电池 %.1f°C", $0) }
                      ?? "电池 n/a")

        let fans: String
        if thermal.fans.isEmpty {
            fans = "n/a"
        } else {
            fans = thermal.fans
                .map { $0.rpm.map { String(format: "%.0f", $0) } ?? "n/a" }
                .joined(separator: "/") + "rpm"
        }
        return "温度 \(pieces.joined(separator: " ")) 风扇 \(fans)"
    }

    // MARK: - JSON

    /// 每拍一行 JSON（JSONL）。key 与约定完全一致，取不到的指标为 null。
    private func jsonLine(snapshot s: SystemSnapshot, sampleMs: Double) -> String {
        let perCore = s.cpu.perCore.map { number($0, decimals: 4) }.joined(separator: ",")
        let gpuName = s.gpu.name.map { "\"\(escape($0))\"" } ?? "null"
        let gpuUtil = s.gpu.utilization.map { number($0, decimals: 4) } ?? "null"
        let gpuInUse = s.gpu.inUseMemory.map { String($0) } ?? "null"
        let gpuAlloc = s.gpu.allocatedMemory.map { String($0) } ?? "null"
        let iface = s.network.interfaceName.map { "\"\(escape($0))\"" } ?? "null"
        let disk: String
        if let d = s.disk {
            disk = "{\"total\":\(d.total),\"free\":\(d.free),\"used\":\(d.used),"
                 + "\"usage\":\(number(d.usage, decimals: 4))}"
        } else {
            disk = "null"
        }

        var out = "{"
        out += "\"index\":\(s.sampleIndex),"
        out += "\"ts\":\"\(timestampFormatter.string(from: s.timestamp))\","
        out += "\"cores\":\(s.cpu.coreCount),"
        out += "\"cpu\":{\"total\":\(number(s.cpu.total, decimals: 4)),"
        out += "\"user\":\(number(s.cpu.user, decimals: 4)),"
        out += "\"system\":\(number(s.cpu.system, decimals: 4)),"
        out += "\"idle\":\(number(s.cpu.idle, decimals: 4)),"
        out += "\"perCore\":[\(perCore)],"
        out += "\"load1\":\(number(s.cpu.load1, decimals: 2)),"
        out += "\"load5\":\(number(s.cpu.load5, decimals: 2)),"
        out += "\"load15\":\(number(s.cpu.load15, decimals: 2))},"
        out += "\"mem\":{\"total\":\(s.memory.total),\"used\":\(s.memory.used),"
        out += "\"free\":\(s.memory.free),\"active\":\(s.memory.active),"
        out += "\"inactive\":\(s.memory.inactive),\"wired\":\(s.memory.wired),"
        out += "\"compressed\":\(s.memory.compressed),\"cached\":\(s.memory.cached),"
        out += "\"swapTotal\":\(s.memory.swapTotal),\"swapUsed\":\(s.memory.swapUsed),"
        out += "\"usage\":\(number(s.memory.usage, decimals: 4))},"
        out += "\"gpu\":{\"name\":\(gpuName),\"util\":\(gpuUtil),"
        out += "\"inUseMem\":\(gpuInUse),\"allocMem\":\(gpuAlloc)},"
        out += "\"net\":{\"down\":\(number(s.network.download, decimals: 1)),"
        out += "\"up\":\(number(s.network.upload, decimals: 1)),"
        out += "\"received\":\(s.network.received),\"sent\":\(s.network.sent),"
        out += "\"iface\":\(iface),\"connected\":\(s.network.isConnected)},"
        out += "\"disk\":\(disk),"
        out += "\"uptime\":\(number(s.uptime, decimals: 3)),"
        // ProcessInfo 的热压力状态改名为 thermalState：thermal 这个 key 留给下面的温度/风扇对象。
        out += "\"thermalState\":\"\(thermalName(s.thermalState))\","
        out += "\"thermal\":\(thermalJSON(s.thermal)),"
        out += "\"sampleMs\":\(number(sampleMs, decimals: 3))"
        out += "}"
        return out
    }

    /// 温度 / 风扇对象。取不到的字段是 null（不是 0），整体结构恒定便于脚本消费。
    private func thermalJSON(_ thermal: ThermalStats) -> String {
        let cpu = thermal.cpuTemperature.map { number($0, decimals: 2) } ?? "null"
        let gpu = thermal.gpuTemperature.map { number($0, decimals: 2) } ?? "null"
        let battery = thermal.batteryTemperature.map { number($0, decimals: 2) } ?? "null"
        let fans = thermal.fans.map { fan -> String in
            let rpm = fan.rpm.map { number($0, decimals: 1) } ?? "null"
            let min = fan.minRPM.map { number($0, decimals: 1) } ?? "null"
            let max = fan.maxRPM.map { number($0, decimals: 1) } ?? "null"
            let target = fan.targetRPM.map { number($0, decimals: 1) } ?? "null"
            return "{\"index\":\(fan.index),\"rpm\":\(rpm),\"min\":\(min),"
                 + "\"max\":\(max),\"target\":\(target)}"
        }.joined(separator: ",")
        let source = thermal.sourceDescription.map { "\"\(escape($0))\"" } ?? "null"
        return "{\"cpuTemp\":\(cpu),\"gpuTemp\":\(gpu),\"batteryTemp\":\(battery),"
             + "\"sensorCount\":\(thermal.sensors.count),\"fans\":[\(fans)],"
             + "\"readMs\":\(number(thermal.readMillis, decimals: 3)),\"source\":\(source)}"
    }

    // MARK: - 小工具

    /// JSON 数值：先四舍五入再交给 String(describing:)，避免本地化小数点。
    private func number(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        var factor = 1.0
        for _ in 0..<decimals { factor *= 10 }
        let rounded = (value * factor).rounded() / factor
        return String(rounded)
    }

    private func escape(_ value: String) -> String {
        var out = ""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out
    }

    func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func formatSeconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// 1024 进制的人类可读字节数（B / K / M / G / T）。
func formatBytes(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0B" }
    let units = ["B", "K", "M", "G", "T", "P"]
    var scaled = value
    var unit = 0
    while scaled >= 1024, unit < units.count - 1 {
        scaled /= 1024
        unit += 1
    }
    if unit == 0 { return String(format: "%.0fB", scaled) }
    return String(format: "%.1f%@", scaled, units[unit])
}
