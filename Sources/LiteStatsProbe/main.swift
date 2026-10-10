// 无头探针：验证传感器数值是否真实合理。
// 用法: swift run --disable-sandbox --scratch-path .build-core litestats-probe [--seconds N] [--interval S] [--json]
import Foundation
import LiteStatsCore

switch ProbeOptions.parse(CommandLine.arguments) {
case .failure(let error):
    FileHandle.standardError.write(Data(("错误: " + error.message + "\n\n" + ProbeOptions.usage + "\n").utf8))
    exit(1)
case .success(let options):
    if options.help {
        print(ProbeOptions.usage)
        exit(0)
    }
    exit(ProbeRunner.run(options))
}
