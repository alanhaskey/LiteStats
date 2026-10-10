import Foundation

/// 偏好设置（UserDefaults 持久化）。少量几项，直接读写，不引入 Combine。
@MainActor
@Observable
final class Preferences {
    private enum Key {
        static let expandedInterval = "expandedInterval"
        static let collapsedInterval = "collapsedInterval"
        static let showMenuBarItem = "showMenuBarItem"
    }

    private let defaults: UserDefaults

    var expandedInterval: Double {
        didSet { defaults.set(expandedInterval, forKey: Key.expandedInterval) }
    }

    var collapsedInterval: Double {
        didSet { defaults.set(collapsedInterval, forKey: Key.collapsedInterval) }
    }

    var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: Key.showMenuBarItem) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedExpanded = defaults.double(forKey: Key.expandedInterval)
        let storedCollapsed = defaults.double(forKey: Key.collapsedInterval)
        self.expandedInterval = storedExpanded > 0 ? storedExpanded : 1.0
        self.collapsedInterval = storedCollapsed > 0 ? storedCollapsed : 2.0
        self.showMenuBarItem = defaults.object(forKey: Key.showMenuBarItem) as? Bool ?? true
    }
}
