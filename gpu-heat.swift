import Foundation
import Metal
import MetalPerformanceShaders

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fputs("no Metal device\n", stderr)
    exit(1)
}
let n = 8192
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
fputs("gpu \(device.name) \(n)x\(n)\n", stderr)
while true {
    autoreleasepool {
        guard let cmd = queue.makeCommandBuffer() else { exit(1) }
        mul.encode(commandBuffer: cmd, leftMatrix: a, rightMatrix: b, resultMatrix: c)
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status != .completed { exit(1) }
    }
}
