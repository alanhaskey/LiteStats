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

    /// 该侧是否需要黑耳（只有选了指标才需要）
    var needsEar: Bool { self != .none }
}

/// 偏好设置（UserDefaults 持久化）。改动通过 `onChange` 即时生效。
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let expandedInterval = "expandedInterval"
        static let collapsedInterval = "collapsedInterval"
        static let showMenuBarItem = "showMenuBarItem"
        static let earWidth = "earWidth"
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

    /// 刘海两侧黑耳的**统一长度**（pt）。两侧一样长、与显示内容无关，内容在其中居中。
    /// 之前是按内容长度自适应，导致换一个指标耳朵就变长变短，看起来很不稳定。
    var earWidth: Double {
        didSet {
            let clamped = min(max(earWidth, 48), 160)
            if clamped != earWidth {
                earWidth = clamped
                return // didSet 会再次进入
            }
            defaults.set(earWidth, forKey: Key.earWidth)
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
        // 默认 88pt：够放 "↓ 1.2M ↑ 32K" 这种最长的指示条，两侧统一
        self.earWidth = defaults.object(forKey: Key.earWidth) != nil
            ? defaults.double(forKey: Key.earWidth) : 88
        // 默认完全不显示：收起态就是"什么都不画"，完全藏进物理刘海里（最隐蔽）。
        // 想要常驻指标去「设置 → 刘海常驻指示条」里选。
        self.leftIndicator = defaults.string(forKey: Key.leftIndicator)
            .flatMap(IndicatorMetric.init(rawValue:)) ?? .none
        self.rightIndicator = defaults.string(forKey: Key.rightIndicator)
            .flatMap(IndicatorMetric.init(rawValue:)) ?? .none
        self.showMenuBarItem = defaults.object(forKey: Key.showMenuBarItem) as? Bool ?? true
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }
}
