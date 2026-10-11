import Foundation
import ServiceManagement

/// 开机自启。
///
/// 优先用 macOS 13+ 的 `SMAppService.mainApp`（系统「登录项」里可见、可被用户管理）；
/// 但本机是 ad-hoc 签名、且开发时常常直接跑 `.build` 里的二进制，
/// 这种情况下 `register()` 会抛错 —— 于是退回写一个 LaunchAgent plist。
/// 两条路都幂等：关闭时两处都清理。
@MainActor
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
                return Localization.shared.t("launch.registered")
            } catch {
                // 常见于：ad-hoc 签名 / 未放在 /Applications —— 退回 LaunchAgent
                return installLaunchAgent(reason: error.localizedDescription)
            }
        }
        return installLaunchAgent(reason: Localization.shared.t("launch.tooOld"))
    }

    private static func installLaunchAgent(reason: String) -> String {
        guard let executable = Bundle.main.executablePath else {
            return Localization.shared.t("launch.noExecutable")
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
            return Localization.shared.t("launch.agent") + "（\(reason)）"
        } catch {
            return Localization.shared.t("launch.failed", error.localizedDescription)
        }
    }

    private static func uninstall() -> String {
        var notes: [String] = []
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                do {
                    try SMAppService.mainApp.unregister()
                    notes.append(Localization.shared.t("launch.removed"))
                } catch {
                    notes.append(Localization.shared.t("launch.removeFailed", error.localizedDescription))
                }
            }
        }
        if hasLaunchAgent {
            do {
                try FileManager.default.removeItem(at: agentURL)
                notes.append(Localization.shared.t("launch.removedAgent"))
            } catch {
                notes.append(Localization.shared.t("launch.deleteFailed", error.localizedDescription))
            }
        }
        return notes.isEmpty ? Localization.shared.t("launch.off") : notes.joined(separator: Localization.shared.t("launch.join"))
    }
}
