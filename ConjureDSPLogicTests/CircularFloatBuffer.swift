//
//  CircularFloatBuffer.swift
//  ConjureDSPLogicTests
//
//  Minimal copy of CircularFloatBuffer from AudioCaptureManager for unit testing.
//  Keep arithmetic bit-identical to the production source.
//

struct CircularFloatBuffer {
    private var storage: [Float]
    private var head: Int = 0
    private var tail: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(contentsOf source: ArraySlice<Float>) {
        for sample in source {
            storage[tail] = sample
            tail = (tail + 1) % capacity
            if count < capacity {
                count += 1
            } else {
                head = (head + 1) % capacity
            }
        }
    }

    func copyPrefix(_ n: Int, into dest: inout [Float]) {
        let n = min(n, count)
        let firstChunk = min(n, capacity - head)
        for i in 0..<firstChunk {
            dest[i] = storage[head + i]
        }
        let secondChunk = n - firstChunk
        for i in 0..<secondChunk {
            dest[firstChunk + i] = storage[i]
        }
    }

    mutating func dropFirst(_ n: Int) {
        let n = min(n, count)
        head = (head + n) % capacity
        count -= n
    }

    mutating func reset() {
        head = 0
        tail = 0
        count = 0
    }
}
