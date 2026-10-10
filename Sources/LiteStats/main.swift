import AppKit

// LiteStats 是常驻后台的 agent 应用（无 Dock 图标、无主窗口），
// 因此不用 SwiftUI 的 App 生命周期，直接手写 NSApplication 启动流程，
// 避免 SwiftUI 场景机制带来的多余窗口与激活行为。
let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    SelfTest.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
