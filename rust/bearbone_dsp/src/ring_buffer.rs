use std::sync::atomic::{AtomicUsize, Ordering};

/// Single-producer, single-consumer lock-free ring buffer for f32 audio samples.
///
/// Designed for the audio visualization pipeline:
/// - Audio thread writes mono-downmixed samples (producer)
/// - UI thread reads samples for FFT/spectrogram (consumer)
///
/// Power-of-2 capacity with bitmask wrap-around. When the buffer is full,
/// new writes overwrite the oldest samples (the audio thread never blocks).
pub struct AudioRingBuffer {
    buffer: Vec<f32>,
    /// Always a power of 2
    capacity: usize,
    /// Monotonically increasing write position (audio thread only)
    write_pos: AtomicUsize,
    /// Monotonically increasing read position (UI thread only)
    read_pos: AtomicUsize,
}

// Safety: The ring buffer is designed for single-producer (audio thread)
// single-consumer (UI thread) use. The atomic positions ensure memory
// visibility between threads.
unsafe impl Send for AudioRingBuffer {}
unsafe impl Sync for AudioRingBuffer {}

impl AudioRingBuffer {
    /// Default capacity: 8192 samples (~185ms at 44.1kHz).
    /// Enough for multiple FFT windows with overlap.
    pub const DEFAULT_CAPACITY: usize = 8192;

    /// Create a new ring buffer with the given capacity (rounded up to next power of 2).
    pub fn new(capacity: usize) -> Self {
        let capacity = capacity.next_power_of_two();
        Self {
            buffer: vec![0.0; capacity],
            capacity,
            write_pos: AtomicUsize::new(0),
            read_pos: AtomicUsize::new(0),
        }
    }

    /// Write samples into the ring buffer. Called from the audio thread.
    ///
    /// If the buffer would overflow, the read position is advanced to discard
    /// oldest samples, ensuring the writer never blocks.
    pub fn write(&self, samples: &[f32]) {
        let write = self.write_pos.load(Ordering::Relaxed);
        let read = self.read_pos.load(Ordering::Acquire);
        let mask = self.capacity - 1;

        // Check if writing would overflow available space
        let available = self.capacity - (write - read);
        if samples.len() > available {
            // Advance read position to make room (discard oldest samples)
            let advance = samples.len() - available;
            self.read_pos.store(read + advance, Ordering::Release);
        }

        // Write samples
        // Safety: we're the only writer (single-producer guarantee)
        let buf = self.buffer.as_ptr() as *mut f32;
        for (i, &sample) in samples.iter().enumerate() {
            let idx = (write + i) & mask;
            unsafe {
                buf.add(idx).write(sample);
            }
        }

        self.write_pos.store(write + samples.len(), Ordering::Release);
    }

    /// Read available samples from the ring buffer. Called from the UI thread.
    ///
    /// Copies up to `output.len()` samples into `output`.
    /// Returns the number of samples actually read.
    pub fn read(&self, output: &mut [f32]) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Relaxed);
        let mask = self.capacity - 1;

        let available = write - read;
        let count = available.min(output.len());

        for i in 0..count {
            let idx = (read + i) & mask;
            output[i] = self.buffer[idx];
        }

        self.read_pos.store(read + count, Ordering::Release);
        count
    }

    /// Number of samples available to read.
    pub fn available(&self) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Relaxed);
        write - read
    }

    /// Clear the buffer (reset read/write positions).
    pub fn clear(&self) {
        self.read_pos.store(0, Ordering::Relaxed);
        self.write_pos.store(0, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_power_of_two() {
        let rb = AudioRingBuffer::new(1000);
        assert_eq!(rb.capacity, 1024);
        let rb = AudioRingBuffer::new(4096);
        assert_eq!(rb.capacity, 4096);
    }

    #[test]
    fn test_write_read_roundtrip() {
        let rb = AudioRingBuffer::new(16);
        let input = [1.0, 2.0, 3.0, 4.0];
        rb.write(&input);

        let mut output = [0.0f32; 4];
        let count = rb.read(&mut output);
        assert_eq!(count, 4);
        assert_eq!(output, [1.0, 2.0, 3.0, 4.0]);
    }

    #[test]
    fn test_empty_read_returns_zero() {
        let rb = AudioRingBuffer::new(16);
        let mut output = [0.0f32; 4];
        let count = rb.read(&mut output);
        assert_eq!(count, 0);
    }

    #[test]
    fn test_partial_read() {
        let rb = AudioRingBuffer::new(16);
        rb.write(&[1.0, 2.0, 3.0]);

        let mut output = [0.0f32; 2];
        let count = rb.read(&mut output);
        assert_eq!(count, 2);
        assert_eq!(output, [1.0, 2.0]);

        // Remaining sample should still be readable
        let count = rb.read(&mut output);
        assert_eq!(count, 1);
        assert_eq!(output[0], 3.0);
    }

    #[test]
    fn test_overflow_discards_oldest() {
        let rb = AudioRingBuffer::new(4); // capacity = 4

        // Write 4 samples (fill buffer)
        rb.write(&[1.0, 2.0, 3.0, 4.0]);
        assert_eq!(rb.available(), 4);

        // Write 2 more — should discard oldest 2
        rb.write(&[5.0, 6.0]);
        assert_eq!(rb.available(), 4);

        let mut output = [0.0f32; 4];
        let count = rb.read(&mut output);
        assert_eq!(count, 4);
        assert_eq!(output, [3.0, 4.0, 5.0, 6.0]);
    }

    #[test]
    fn test_wrap_around() {
        let rb = AudioRingBuffer::new(4); // capacity = 4

        // Write and read to advance positions past capacity
        rb.write(&[1.0, 2.0, 3.0]);
        let mut out = [0.0f32; 3];
        rb.read(&mut out);
        assert_eq!(out, [1.0, 2.0, 3.0]);

        // Now write/read across the wrap boundary
        rb.write(&[4.0, 5.0, 6.0]);
        let count = rb.read(&mut out);
        assert_eq!(count, 3);
        assert_eq!(out, [4.0, 5.0, 6.0]);
    }

    #[test]
    fn test_available() {
        let rb = AudioRingBuffer::new(16);
        assert_eq!(rb.available(), 0);

        rb.write(&[1.0, 2.0, 3.0]);
        assert_eq!(rb.available(), 3);

        let mut out = [0.0f32; 2];
        rb.read(&mut out);
        assert_eq!(rb.available(), 1);
    }

    #[test]
    fn test_clear() {
        let rb = AudioRingBuffer::new(16);
        rb.write(&[1.0, 2.0, 3.0]);
        assert_eq!(rb.available(), 3);

        rb.clear();
        assert_eq!(rb.available(), 0);

        let mut out = [0.0f32; 3];
        let count = rb.read(&mut out);
        assert_eq!(count, 0);
    }

    #[test]
    fn test_multiple_writes_then_read() {
        let rb = AudioRingBuffer::new(16);
        rb.write(&[1.0, 2.0]);
        rb.write(&[3.0, 4.0]);
        rb.write(&[5.0]);

        let mut output = [0.0f32; 5];
        let count = rb.read(&mut output);
        assert_eq!(count, 5);
        assert_eq!(output, [1.0, 2.0, 3.0, 4.0, 5.0]);
    }

    #[test]
    fn test_read_more_than_available() {
        let rb = AudioRingBuffer::new(16);
        rb.write(&[1.0, 2.0]);

        let mut output = [0.0f32; 8];
        let count = rb.read(&mut output);
        assert_eq!(count, 2);
        assert_eq!(output[0], 1.0);
        assert_eq!(output[1], 2.0);
    }

    #[test]
    fn test_default_capacity() {
        let rb = AudioRingBuffer::new(AudioRingBuffer::DEFAULT_CAPACITY);
        assert_eq!(rb.capacity, 8192);
    }
}
