import Foundation

/// 常驻指示条可以显示的内容（刘海左右各可选一个）。
enum IndicatorMetric: String, CaseIterable, Identifiable, Sendable {
    case none
    case cpu
    case memory
    case gpu
    case network
    case disk
    case temperature
    case fan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不显示"
        case .cpu: return "CPU 占用"
        case .memory: return "内存占用"
        case .gpu: return "GPU 占用"
        case .network: return "网络上下行"
        case .disk: return "磁盘占用"
        case .temperature: return "CPU 温度"
        case .fan: return "风扇转速"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "minus"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cube.transparent"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive"
        case .temperature: return "thermometer.medium"
        case .fan: return "fan"
        }
    }

    /// 指示条在该侧需要的宽度（pt：按最长文本实测预留，宁可宽一点也别让字被压缩变形）
    var indicatorWidth: CGFloat {
        switch self {
        case .none: return 0
        case .cpu, .memory, .gpu, .disk: return 64
        case .temperature: return 58
        case .fan: return 72
        case .network: return 100
        }
    }
}

/// 偏好设置（UserDefaults 持久化）。改动通过 `onChange` 即时生效。
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let expandedInterval = "expandedInterval"
        static let collapsedInterval = "collapsedInterval"
        static let showMenuBarItem = "showMenuBarItem"
        static let tabFlank = "tabFlank"
        static let leftIndicator = "leftIndicator"
        static let rightIndicator = "rightIndicator"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults

    /// 采样间隔（秒）：展开态 / 收起态
    var expandedInterval: Double {
        didSet { defaults.set(expandedInterval, forKey: Key.expandedInterval); onChange?() }
    }
    var collapsedInterval: Double {
        didSet { defaults.set(collapsedInterval, forKey: Key.collapsedInterval); onChange?() }
    }

    /// 岛颈（黑色耳朵）在刘海左右各外扩多少 pt。不同机型刘海宽度不同，这里让用户微调。
    var tabFlank: Double {
        didSet {
            let clamped = min(max(tabFlank, 0), 60)
            if clamped != tabFlank {
                tabFlank = clamped
                return // didSet 会再次进入
            }
            defaults.set(tabFlank, forKey: Key.tabFlank)
            onChange?()
        }
    }

    var leftIndicator: IndicatorMetric {
        didSet { defaults.set(leftIndicator.rawValue, forKey: Key.leftIndicator); onChange?() }
    }
    var rightIndicator: IndicatorMetric {
        didSet { defaults.set(rightIndicator.rawValue, forKey: Key.rightIndicator); onChange?() }
    }

    var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: Key.showMenuBarItem); onChange?() }
    }
    var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    /// 任一影响布局/采样的改动后触发（由 AppDelegate 设置）
    var onChange: (() -> Void)?

    var hasIndicators: Bool { leftIndicator != .none || rightIndicator != .none }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let expanded = defaults.double(forKey: Key.expandedInterval)
        let collapsed = defaults.double(forKey: Key.collapsedInterval)
        self.expandedInterval = expanded > 0 ? expanded : 1.0
        self.collapsedInterval = collapsed > 0 ? collapsed : 2.0
        // 默认 24pt：岛颈在物理刘海左右各露出一小截黑耳
        self.tabFlank = defaults.object(forKey: Key.tabFlank) != nil
            ? defaults.double(forKey: Key.tabFlank) : 24
        self.leftIndicator = defaults.string(forKey: Key.leftIndicator)
            .flatMap(IndicatorMetric.init(rawValue:)) ?? .none
        // 默认在右侧常驻一个 CPU 占用：用户要求的"刘海两侧指示条"至少要能一眼看见，
        // 不想要的话在设置里改成"不显示"即可。
        self.rightIndicator = defaults.string(forKey: Key.rightIndicator)
            .flatMap(IndicatorMetric.init(rawValue:)) ?? .cpu
        self.showMenuBarItem = defaults.object(forKey: Key.showMenuBarItem) as? Bool ?? true
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }
}
