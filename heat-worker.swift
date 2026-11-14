import Foundation
import Metal
import MetalPerformanceShaders

// Load generator for HeatBar. `heat-worker cpu` spins every logical CPU,
// `heat-worker gpu` runs Metal matrix multiplies. The duty level (0...1) is
// read from stdin, one number per line. The worker exits when stdin closes,
// so it cannot outlive the app that started it.

let period = 0.05
let levelLock = NSLock()
var sharedLevel = 1.0

func currentLevel() -> Double {
    levelLock.lock()
    defer { levelLock.unlock() }
    return sharedLevel
}

func now() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

// Runs `work(seconds)` for `level` of the time. Sleeps are measured after the
// fact and the next burst is sized from what was really slept, so a late
// wake-up or a long burst does not pull the average away from the target.
func pace(offset: Double, work: (Double) -> Void) -> Never {
    if offset > 0 { Thread.sleep(forTimeInterval: offset) }
    var owed = 0.0
    while true {
        let level = currentLevel()
        if level <= 0.001 {
            owed = 0
            Thread.sleep(forTimeInterval: period)
            continue
        }
        if level >= 0.995 {
            owed = 0
            work(period)
            continue
        }
        let idleFor = (1 - level) * period + max(0, -owed) * (1 - level) / level
        let slept = now()
        Thread.sleep(forTimeInterval: idleFor)
        owed += (now() - slept) * level / (1 - level)
        owed = min(max(owed, -1), 1)
        if owed > 0 {
            let began = now()
            work(owed)
            owed -= now() - began
        }
    }
}

func runCPU() {
    let count = ProcessInfo.processInfo.activeProcessorCount
    for index in 0..<count {
        let thread = Thread {
            var x = 1.000001
            pace(offset: period * Double(index) / Double(count)) { seconds in
                let end = now() + seconds
                repeat {
                    for _ in 0..<512 { x = x * 1.0000001 + 0.0000001 }
                    if x > 1e30 { x = 1.000001 }
                } while now() < end
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

func runGPU() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fputs("no Metal device\n", stderr)
        exit(1)
    }
    let n = 4096
    let rowBytes = n * MemoryLayout<Float>.size
    let desc = MPSMatrixDescriptor(rows: n, columns: n, rowBytes: rowBytes, dataType: .float32)
    guard
        let bufA = device.makeBuffer(length: n * rowBytes, options: .storageModeShared),
        let bufB = device.makeBuffer(length: n * rowBytes, options: .storageModeShared),
        let bufC = device.makeBuffer(length: n * rowBytes, options: .storageModeShared)
    else {
        fputs("gpu alloc failed\n", stderr)
        exit(1)
    }
    let mul = MPSMatrixMultiplication(
        device: device,
        transposeLeft: false,
        transposeRight: false,
        resultRows: n,
        resultColumns: n,
        interiorColumns: n,
        alpha: 1,
        beta: 0
    )
    let a = MPSMatrix(buffer: bufA, descriptor: desc)
    let b = MPSMatrix(buffer: bufB, descriptor: desc)
    let c = MPSMatrix(buffer: bufC, descriptor: desc)
    let thread = Thread {
        pace(offset: 0) { seconds in
            let end = now() + seconds
            repeat {
                autoreleasepool {
                    guard let cmd = queue.makeCommandBuffer() else { exit(1) }
                    mul.encode(commandBuffer: cmd, leftMatrix: a, rightMatrix: b, resultMatrix: c)
                    cmd.commit()
                    cmd.waitUntilCompleted()
                    if cmd.status != .completed { exit(1) }
                }
            } while now() < end
        }
    }
    thread.qualityOfService = .userInitiated
    thread.start()
}

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
guard arguments.count >= 2, ["cpu", "gpu"].contains(arguments[1]) else {
    fputs("usage: heat-worker cpu|gpu [level]\n", stderr)
    exit(2)
}
if arguments.count >= 3, let initial = Double(arguments[2]) {
    sharedLevel = min(max(initial, 0), 1)
}
if arguments[1] == "cpu" { runCPU() } else { runGPU() }
while let line = readLine() {
    guard let value = Double(line.trimmingCharacters(in: .whitespaces)) else { continue }
    levelLock.lock()
    sharedLevel = min(max(value, 0), 1)
    levelLock.unlock()
}
exit(0)
