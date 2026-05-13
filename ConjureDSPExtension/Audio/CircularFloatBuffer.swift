//
//  CircularFloatBuffer.swift
//  ConjureDSPExtension
//
//  Fixed-capacity circular buffer for audio sample accumulation.
//  Used by AudioCaptureManager to hold pending input/output samples
//  between display-link ticks while the FFT consumes overlapping
//  windows. Extracted to its own file so ConjureDSPLogicTests can
//  compile against the same source the appex uses (no hand-copy drift).
//

/// Fixed-capacity circular buffer for audio sample accumulation.
/// Replaces `[Float]` + `append`/`removeFirst` to avoid O(n) copies
/// and capacity ratcheting.
struct CircularFloatBuffer {
    private var storage: [Float]
    private var head: Int = 0     // read position
    private var tail: Int = 0     // write position
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Append samples. Drops oldest if buffer would overflow.
    mutating func append(contentsOf source: ArraySlice<Float>) {
        for sample in source {
            storage[tail] = sample
            tail = (tail + 1) % capacity
            if count < capacity {
                count += 1
            } else {
                head = (head + 1) % capacity  // overwrite oldest
            }
        }
    }

    /// Copy the first `n` elements into `dest` (must have at least `n` elements).
    /// Handles wrap-around transparently.
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

    /// Advance the read position by `n`, discarding the oldest samples. O(1).
    mutating func dropFirst(_ n: Int) {
        let n = min(n, count)
        head = (head + n) % capacity
        count -= n
    }

    /// Reset to empty state without releasing memory.
    mutating func reset() {
        head = 0
        tail = 0
        count = 0
    }
}
