import Foundation

/// 数值格式化。全部标 `@inline(__always)` 无关紧要——每秒最多调用几十次。
enum Fmt {
    private static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 字节 → 人类可读（1024 进制，1 位小数；B 不带小数）
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        var v = max(0, value)
        var idx = 0
        while v >= 1024, idx < byteUnits.count - 1 {
            v /= 1024
            idx += 1
        }
        if idx == 0 { return "\(Int(v)) B" }
        return String(format: "%.1f %@", v, byteUnits[idx])
    }

    /// 字节/秒 → “1.2 MB/s”
    static func rate(_ value: Double) -> String {
        guard value >= 1 else { return "0 B/s" }
        return bytes(value) + "/s"
    }

    /// 字节/秒 → 极简形式（常驻指示条宽度有限）："1.2G" / "1.2M" / "32K" / "0"
    static func compactRate(_ value: Double) -> String {
        guard value >= 1 else { return "0" }
        if value >= 1_073_741_824 { return String(format: "%.1fG", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1fM", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0fK", value / 1024) }
        return String(format: "%.0f", value)
    }

    /// 0...1 → “12.4%”
    static func percent(_ value: Double, decimals: Int = 1) -> String {
        let pct = min(max(value, 0), 1) * 100
        return decimals == 0 ? "\(Int(pct.rounded()))%" : String(format: "%.\(decimals)f%%", pct)
    }

    /// 带符号的百分数，用于每核心等小字号场景
    static func percentInt(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))"
    }

    /// 秒 → “3 天 4 小时”
    @MainActor
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return Localization.shared.t("uptime.daysHours", days, hours) }
        if hours > 0 { return Localization.shared.t("uptime.hoursMinutes", hours, minutes) }
        return Localization.shared.t("uptime.minutes", minutes)
    }
}
