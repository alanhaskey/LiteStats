import Foundation
import Observation

/// 界面语言。默认**跟随系统**，也可以在设置里手动指定。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    /// 设置里显示的名字
    @MainActor var title: String {
        switch self {
        case .system: return Localization.shared.t("language.system")
        case .chinese: return Localization.shared.t("language.chinese")
        case .english: return Localization.shared.t("language.english")
        }
    }

    /// 解析后的实际语言（`.system` 已按系统偏好展开）
    enum Resolved: String, Sendable {
        case chinese = "zh-Hans"
        case english = "en"

        var locale: Locale { Locale(identifier: rawValue) }
    }

    /// 按系统偏好解析。简体中文（含 zh、zh-Hans、zh-CN…）走中文，其余走英文。
    static func resolveSystem(_ preferred: [String] = Locale.preferredLanguages) -> Resolved {
        guard let first = preferred.first?.lowercased() else { return .english }
        return first.hasPrefix("zh") ? .chinese : .english
    }
}

/// 当前语言的进程级快照（带锁）。
///
/// 为什么需要它：`Localization` 是 `@MainActor @Observable`（供 SwiftUI 订阅），
/// 但纯函数、枚举、格式化器里也要取文案，从非隔离上下文访问会编译不过。
/// 这里存一份加锁的快照，配合全局函数 `L(_:)` 让任何上下文都能安全取文案。
final class LanguageStore: @unchecked Sendable {
    static let shared = LanguageStore()
    private let lock = NSLock()
    private var value: AppLanguage.Resolved = AppLanguage.resolveSystem()

    var current: AppLanguage.Resolved {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// 取一条文案（任意上下文可用）。SwiftUI 视图请在 body 里引用一次
/// `Localization.shared.resolved` 以订阅语言变化。
func L(_ key: String) -> String {
    Localization.text(key, language: LanguageStore.shared.current)
}

/// 带参数的文案
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

/// 文案表与查询入口。
///
/// 为什么不用 `.lproj` / `Localizable.strings`：只有中英两种语言，而**运行时切换**需要
/// 自己加载对应 bundle、还要处理缺失键。用一张代码内的表更简单 —— 键和两种语言写在一起，
/// 缺一条一眼就能看出来（自检里断言两种语言都不为空），切换语言只需换一个字段。
@Observable
@MainActor
final class Localization {
    static let shared = Localization()

    /// 用户在设置里选的语言
    var language: AppLanguage = .system {
        didSet {
            guard language != oldValue else { return }
            let next = Self.resolve(language)
            resolved = next
            LanguageStore.shared.current = next       // 供非隔离上下文查询
        }
    }

    private(set) var resolved: AppLanguage.Resolved = AppLanguage.resolveSystem() {
        didSet { LanguageStore.shared.current = resolved }
    }

    /// 纯查询（任意上下文可用）
    nonisolated static func text(_ key: String, language: AppLanguage.Resolved) -> String {
        guard let entry = table[key] else {
            assertionFailure("缺少文案：\(key)")
            return key
        }
        return language == .chinese ? entry.zh : entry.en
    }

    static func resolve(_ language: AppLanguage) -> AppLanguage.Resolved {
        switch language {
        case .system: return AppLanguage.resolveSystem()
        case .chinese: return .chinese
        case .english: return .english
        }
    }

    var isChinese: Bool { resolved == .chinese }
    var locale: Locale { resolved.locale }

    /// 取一条文案。读取时会访问 `resolved`，所以 SwiftUI 视图里调用它会自动订阅语言变化。
    func t(_ key: String) -> String {
        Self.text(key, language: resolved)
    }

    /// 带参数的文案（`%@` / `%.1f` 占位符）
    func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    // MARK: - 日期 / 星期（跟随语言的区域格式，而不是硬编码"月/日"）

    private var calendar: Calendar = .current
    private var localeIdentifier: String { resolved.rawValue }

    func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter
    }

    func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: date)
    }

    func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    /// 日历表头：中文用「一…日」，英文用区域化的短星期名
    var weekdaySymbols: [String] {
        var symbols: [String]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        symbols = formatter.shortWeekdaySymbols      // 周日开头
        // 首列改成周一
        let mondayFirst = Array(symbols.dropFirst()) + [symbols[0]]
        return isChinese ? ["一", "二", "三", "四", "五", "六", "日"] : mondayFirst
    }

    // MARK: - 文案表

    struct Entry {
        let zh: String
        let en: String
    }

    nonisolated static let table: [String: Entry] = [
        // 菜单栏
        "menu.tooltip": Entry(zh: "LiteStats — 悬浮刘海查看系统状态", en: "LiteStats — hover the notch for system status"),
        "menu.history": Entry(zh: "历史统计", en: "History"),
        "menu.settings": Entry(zh: "设置…", en: "Settings…"),
        "menu.quit": Entry(zh: "退出 LiteStats", en: "Quit LiteStats"),

        // 指标名（设置里的下拉）
        "metric.none": Entry(zh: "不显示", en: "None"),
        "metric.cpu": Entry(zh: "CPU 占用", en: "CPU usage"),
        "metric.memory": Entry(zh: "内存占用", en: "Memory usage"),
        "metric.gpu": Entry(zh: "GPU 占用", en: "GPU usage"),
        "metric.network": Entry(zh: "网络上下行", en: "Network"),
        "metric.disk": Entry(zh: "磁盘占用", en: "Disk usage"),
        "metric.temperature": Entry(zh: "CPU 温度", en: "CPU temperature"),
        "metric.fan": Entry(zh: "风扇转速", en: "Fan speed"),

        // 显示位置
        "display.auto": Entry(zh: "自动", en: "Automatic"),
        "display.main": Entry(zh: "主屏", en: "Main display"),
        "display.all": Entry(zh: "全部屏幕", en: "All displays"),
        "display.specific": Entry(zh: "指定屏幕", en: "Specific display"),
        "display.mainMark": Entry(zh: "主屏", en: "main"),
        "display.notchMark": Entry(zh: "有刘海", en: "notch"),
        "display.noNotchMark": Entry(zh: "无刘海", en: "no notch"),

        // 设置界面
        "settings.title": Entry(zh: "设置", en: "Settings"),
        "settings.measuring": Entry(zh: "测量中…", en: "Measuring…"),
        "settings.enabled": Entry(zh: "当前已启用", en: "Enabled"),
        "settings.disabled": Entry(zh: "当前未启用", en: "Not enabled"),
        "section.indicators": Entry(zh: "刘海常驻指示条", en: "Notch indicators"),
        "settings.leftMetric": Entry(zh: "左侧显示", en: "Left side"),
        "settings.rightMetric": Entry(zh: "右侧显示", en: "Right side"),
        "settings.earWidth": Entry(zh: "黑耳长度", en: "Indicator width"),
        "settings.preview": Entry(zh: "预览", en: "Preview"),
        "section.display": Entry(zh: "显示位置", en: "Display"),
        "settings.showOn": Entry(zh: "显示在", en: "Show on"),
        "settings.screen": Entry(zh: "屏幕", en: "Screen"),
        "section.language": Entry(zh: "语言", en: "Language"),
        "settings.language": Entry(zh: "界面语言", en: "Language"),
        "language.system": Entry(zh: "跟随系统", en: "System"),
        "language.chinese": Entry(zh: "简体中文", en: "简体中文"),
        "language.english": Entry(zh: "English", en: "English"),
        "section.sampling": Entry(zh: "采样", en: "Sampling"),
        "settings.expandedInterval": Entry(zh: "展开时刷新", en: "Refresh when open"),
        "settings.collapsedInterval": Entry(zh: "收起时刷新", en: "Refresh when collapsed"),
        "interval.secondsFloat": Entry(zh: "%.1f 秒", en: "%.1f s"),
        "interval.secondsInt": Entry(zh: "%d 秒", en: "%d s"),
        "section.general": Entry(zh: "通用", en: "General"),
        "settings.menuBarIcon": Entry(zh: "在菜单栏显示图标", en: "Show menu bar icon"),
        "settings.launchAtLogin": Entry(zh: "开机自动启动", en: "Launch at login"),
        "section.history": Entry(zh: "历史统计", en: "History"),
        "settings.historyNote": Entry(zh: "本地记录流量、CPU/GPU/内存与应用占用", en: "Records traffic, CPU/GPU/memory and per-app usage locally"),
        "settings.openHistory": Entry(zh: "打开历史统计…", en: "Open History…"),
        "section.about": Entry(zh: "关于", en: "About"),
        "settings.version": Entry(zh: "版本", en: "Version"),
        "settings.cost": Entry(zh: "本 App 开销", en: "This app's cost"),
        "settings.costValue": Entry(zh: "%.2f%% CPU · %.1f MB 物理占用", en: "%.2f%% CPU · %.1f MB physical"),
        "settings.quit": Entry(zh: "退出 LiteStats", en: "Quit LiteStats"),

        // 面板
        "panel.temperature": Entry(zh: "温度", en: "Temp"),
        "panel.fan": Entry(zh: "风扇", en: "Fans"),
        "panel.cores": Entry(zh: "%d 核", en: "%d cores"),
        "panel.userSystemIdle": Entry(zh: "用户 %@ · 系统 %@ · 空闲 %@", en: "User %@ · System %@ · Idle %@"),
        "panel.load": Entry(zh: "负载 %@", en: "Load %@"),
        "panel.vram": Entry(zh: "显存 %@", en: "VRAM %@"),
        "panel.unavailable": Entry(zh: "不可用", en: "N/A"),
        "panel.memory": Entry(zh: "内存", en: "Memory"),
        "panel.swap": Entry(zh: " · 交换 %@", en: " · swap %@"),
        "panel.cached": Entry(zh: " · 缓存 %@", en: " · cached %@"),
        "panel.network": Entry(zh: "网络", en: "Network"),
        "panel.gateway": Entry(zh: "网关 %@", en: "Gateway %@"),
        "connection.wifi": Entry(zh: "Wi-Fi", en: "Wi-Fi"),
        "connection.ethernet": Entry(zh: "以太网", en: "Ethernet"),
        "connection.cellular": Entry(zh: "蜂窝网络", en: "Cellular"),
        "connection.vpn": Entry(zh: "VPN", en: "VPN"),
        "connection.bridge": Entry(zh: "网桥", en: "Bridge"),
        "connection.bond": Entry(zh: "链路聚合", en: "Bond"),
        "connection.vlan": Entry(zh: "VLAN", en: "VLAN"),
        "connection.other": Entry(zh: "其他网络", en: "Other network"),
        "connection.unknown": Entry(zh: "网络", en: "Network"),
        "panel.noAddress": Entry(zh: "未分配地址", en: "No address"),
        "panel.uptime": Entry(zh: "已开机 %@", en: "Up %@"),
        "panel.diskEmpty": Entry(zh: "磁盘 —", en: "Disk —"),
        "panel.disk": Entry(zh: "磁盘 %@ 已用 · 可用 %@", en: "Disk %@ used · %@ free"),

        // 运行时长
        "uptime.daysHours": Entry(zh: "%d 天 %d 小时", en: "%dd %dh"),
        "uptime.hoursMinutes": Entry(zh: "%d 小时 %d 分", en: "%dh %dm"),
        "uptime.minutes": Entry(zh: "%d 分", en: "%dm"),

        // 历史统计
        "history.title": Entry(zh: "历史统计", en: "History"),
        "history.today": Entry(zh: "今天", en: "Today"),
        "history.last7": Entry(zh: "近 7 天", en: "Last 7 days"),
        "history.thisMonth": Entry(zh: "本月", en: "This month"),
        "history.heatLegend": Entry(zh: "格子深浅 = %@", en: "Shading = %@"),
        "history.download": Entry(zh: "网络下载", en: "Downloaded"),
        "history.upload": Entry(zh: "网络上行", en: "Uploaded"),
        "history.cpuTotal": Entry(zh: "CPU 累计", en: "CPU total"),
        "history.memoryAverage": Entry(zh: "内存均值", en: "Memory avg"),
        "history.hourlyLoad": Entry(zh: "各时段负载", en: "Load by hour"),
        "history.dailyLoad": Entry(zh: "每天负载", en: "Load by day"),
        "history.peak": Entry(zh: "峰值 %@ · %@", en: "Peak %@ · %@"),
        "history.peakHourSuffix": Entry(zh: "%@ 时段", en: "%@ hour"),
        "history.noRecords": Entry(zh: "这段时间还没有记录", en: "No data for this period"),
        "history.appRanking": Entry(zh: "应用排行", en: "Top apps"),
        "history.noAppRecords": Entry(zh: "这段时间还没有按应用的记录", en: "No per-app data for this period"),
        "history.localStorage": Entry(zh: "本地存储 %@", en: "Local storage %@"),
        "history.clear": Entry(zh: "清空数据", en: "Clear data"),
        "history.clearTitle": Entry(zh: "确定清空全部历史统计？", en: "Clear all history?"),
        "history.clearConfirm": Entry(zh: "清空", en: "Clear"),
        "history.cancel": Entry(zh: "取消", en: "Cancel"),
        "history.clearMessage": Entry(
            zh: "会删除本地保存的网络流量、CPU/GPU/内存与应用占用记录，且无法恢复。",
            en: "This deletes all locally stored traffic, CPU/GPU/memory and per-app records. It cannot be undone."),
        "history.cleared": Entry(zh: "已清空", en: "Cleared"),
        "history.clearFailed": Entry(zh: "清空失败：%@", en: "Clear failed: %@"),
        "history.noRecord": Entry(zh: "无记录", en: "No data"),
        "history.coreHours": Entry(zh: "%.1f 核·时", en: "%.1f core·h"),
        "history.coreMinutes": Entry(zh: "%.0f 核·分", en: "%.0f core·min"),
        "history.coreSeconds": Entry(zh: "%.1f 核·秒", en: "%.1f core·s"),
        "history.metricCPU": Entry(zh: "CPU", en: "CPU"),
        "history.metricNetwork": Entry(zh: "网络", en: "Network"),
        "history.metricMemory": Entry(zh: "内存", en: "Memory"),

        // 开机自启状态
        "launch.registered": Entry(zh: "已通过系统登录项注册", en: "Registered as a login item"),
        "launch.agent": Entry(zh: "已写入 LaunchAgent", en: "Added a LaunchAgent"),
        "launch.off": Entry(zh: "已关闭（原本未启用）", en: "Off (was not enabled)"),
        "launch.removed": Entry(zh: "已从系统登录项移除", en: "Removed from login items"),
        "launch.removedAgent": Entry(zh: "已删除 LaunchAgent", en: "Removed the LaunchAgent"),
        "launch.tooOld": Entry(zh: "系统版本低于 13", en: "requires macOS 13 or later"),
        "launch.noExecutable": Entry(zh: "找不到可执行文件路径", en: "could not locate the executable"),
        "launch.failed": Entry(zh: "设置失败：%@", en: "Failed: %@"),
        "launch.removeFailed": Entry(zh: "移除登录项失败：%@", en: "Could not remove the login item: %@"),
        "launch.deleteFailed": Entry(zh: "删除 LaunchAgent 失败：%@", en: "Could not delete the LaunchAgent: %@"),
        "launch.join": Entry(zh: "；", en: "; "),

        // 提示框
        "alert.historyUnavailable": Entry(zh: "历史统计不可用", en: "History unavailable"),
        "alert.historyStorageFailed": Entry(
            zh: "创建本地存储目录失败：\n\n%@\n\n路径：%@",
            en: "Could not create the local storage folder:\n\n%@\n\nPath: %@"),
        "alert.historyNotInitialized": Entry(zh: "本地存储尚未初始化。", en: "Local storage has not been initialized."),
        "alert.retry": Entry(zh: "重试", en: "Retry"),
        "alert.close": Entry(zh: "关闭", en: "Close"),
    ]
}
