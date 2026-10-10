import Foundation
import ServiceManagement

/// 开机自启。
///
/// 优先用 macOS 13+ 的 `SMAppService.mainApp`（系统「登录项」里可见、可被用户管理）；
/// 但本机是 ad-hoc 签名、且开发时常常直接跑 `.build` 里的二进制，
/// 这种情况下 `register()` 会抛错 —— 于是退回写一个 LaunchAgent plist。
/// 两条路都幂等：关闭时两处都清理。
enum LaunchAtLogin {
    static let agentLabel = "dev.litestats.app"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var hasLaunchAgent: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// 当前是否已启用（两个来源任一存在即视为启用）
    static var isEnabled: Bool {
        if hasLaunchAgent { return true }
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 返回给用户看的状态描述
    @discardableResult
    static func set(enabled: Bool) -> String {
        enabled ? install() : uninstall()
    }

    private static func install() -> String {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                return "已通过系统登录项注册（SMAppService）"
            } catch {
                // 常见于：ad-hoc 签名 / 未放在 /Applications —— 退回 LaunchAgent
                return installLaunchAgent(reason: error.localizedDescription)
            }
        }
        return installLaunchAgent(reason: "系统版本低于 13")
    }

    private static func installLaunchAgent(reason: String) -> String {
        guard let executable = Bundle.main.executablePath else {
            return "找不到可执行文件路径，无法设置开机自启"
        }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background",
        ]
        do {
            let folder = agentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            return "已写入 LaunchAgent（SMAppService 不可用：\(reason)）"
        } catch {
            return "设置失败：\(error.localizedDescription)"
        }
    }

    private static func uninstall() -> String {
        var notes: [String] = []
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                do {
                    try SMAppService.mainApp.unregister()
                    notes.append("已从系统登录项移除")
                } catch {
                    notes.append("移除登录项失败：\(error.localizedDescription)")
                }
            }
        }
        if hasLaunchAgent {
            do {
                try FileManager.default.removeItem(at: agentURL)
                notes.append("已删除 LaunchAgent")
            } catch {
                notes.append("删除 LaunchAgent 失败：\(error.localizedDescription)")
            }
        }
        return notes.isEmpty ? "已关闭（原本未启用）" : notes.joined(separator: "；")
    }
}
