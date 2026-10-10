// 光标移动小工具：给端到端测试用（把光标移到刘海上，验证悬浮展开链路）。
// 用 CGWarpMouseCursorPosition，不需要辅助功能授权。
//
//   swiftc -O -o /tmp/cursor-warp tools/cursor-warp.swift -framework CoreGraphics
//   /tmp/cursor-warp get            # 打印当前光标位置（CG 全局坐标，原点=主屏左上）
//   /tmp/cursor-warp <x> <y>        # 移动光标到 (x, y)
import CoreGraphics
import Foundation

let args = CommandLine.arguments

func currentLocation() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

if args.count >= 2, args[1] == "get" {
    let location = currentLocation()
    print(String(format: "%.1f %.1f", location.x, location.y))
    exit(0)
}

guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("用法: cursor-warp <x> <y> | cursor-warp get\n".utf8))
    exit(2)
}

CGAssociateMouseAndMouseCursorPosition(1)
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
usleep(120_000)
let location = currentLocation()
print(String(format: "%.1f %.1f", location.x, location.y))
