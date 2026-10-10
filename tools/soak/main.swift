
import Foundation

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let bytes: UInt64 = withUnsafeMutablePointer(to: &info) { pointer -> UInt64 in
        let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: integer_t.self)
        guard task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count) == KERN_SUCCESS else { return 0 }
        return pointer.pointee.resident_size
    }
    return Double(bytes) / 1_048_576
}

let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
let iterations = CommandLine.arguments.count > 2 ? (Int(CommandLine.arguments[2]) ?? 6000) : 6000

let gpu = GPUSensor()
let cpu = CPUSensor()
let net = NetworkSensor()
let mem = MemorySensor()
let disk = DiskSensor()
let monitor = SystemMonitor()
var tick = 0

func body() {
    tick += 1
    switch which {
    case "cpu": _ = cpu.sample()
    case "net": _ = net.sample(now: Double(tick) * 0.1)
    case "gpu": _ = gpu.sample(tick: tick)
    case "mem": _ = mem.sample()
    case "disk": _ = disk.sample()
    default: _ = monitor.sample()
    }
}

for _ in 0..<300 { body() }
let before = rssMB()
for _ in 0..<iterations { body() }
let after = rssMB()
print(String(format: "%-8@ %6d 拍  RSS %.2f → %.2f MB  增长 %+.2f MB  %.1f B/拍",
             which as NSString, iterations, before, after, after - before, (after - before) * 1_048_576 / Double(iterations)))
