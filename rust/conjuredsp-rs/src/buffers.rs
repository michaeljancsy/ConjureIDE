/// Fixed-size circular delay buffer.
///
/// `SIZE` must be a compile-time constant. Store in `static mut` for persistence
/// across callbacks.
///
/// ```ignore
/// static mut DELAYS: [DelayLine<48000>; 2] = [DelayLine::new(); 2];
/// ```
#[derive(Clone, Copy)]
pub struct DelayLine<const SIZE: usize> {
    buf: [f32; SIZE],
    write_pos: usize,
}

impl<const SIZE: usize> DelayLine<SIZE> {
    /// Create a zeroed delay line.
    pub const fn new() -> Self {
        DelayLine {
            buf: [0.0; SIZE],
            write_pos: 0,
        }
    }

    /// Write a sample and advance the write head.
    #[inline]
    pub fn write(&mut self, sample: f32) {
        self.buf[self.write_pos] = sample;
        self.write_pos = (self.write_pos + 1) % SIZE;
    }

    /// Read from the delay line with linear interpolation.
    #[inline]
    pub fn read(&self, delay_samples: f64) -> f32 {
        let read_pos = self.write_pos as f64 - delay_samples;
        let read_pos = if read_pos < 0.0 {
            read_pos + SIZE as f64
        } else {
            read_pos
        };
        let idx = read_pos as usize;
        let frac = (read_pos - idx as f64) as f32;
        let idx0 = idx % SIZE;
        let idx1 = (idx + 1) % SIZE;
        self.buf[idx0] * (1.0 - frac) + self.buf[idx1] * frac
    }

    /// Read with cubic (Hermite) interpolation.
    ///
    /// Better quality than linear for pitch shifting and modulated delays.
    #[inline]
    pub fn read_cubic(&self, delay_samples: f64) -> f32 {
        let read_pos = self.write_pos as f64 - delay_samples;
        let read_pos = if read_pos < 0.0 {
            read_pos + SIZE as f64
        } else {
            read_pos
        };
        let idx = read_pos as usize;
        let frac = (read_pos - idx as f64) as f32;

        let y0 = self.buf[(idx + SIZE - 1) % SIZE];
        let y1 = self.buf[idx % SIZE];
        let y2 = self.buf[(idx + 1) % SIZE];
        let y3 = self.buf[(idx + 2) % SIZE];

        let c0 = y1;
        let c1 = 0.5 * (y2 - y0);
        let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
        c0 + frac * (c1 + frac * (c2 + frac * c3))
    }

    /// Read at integer delay (no interpolation).
    #[inline]
    pub fn tap(&self, delay_samples: usize) -> f32 {
        self.buf[(self.write_pos + SIZE - delay_samples) % SIZE]
    }

    /// Zero the entire buffer and reset write position.
    pub fn clear(&mut self) {
        self.buf = [0.0; SIZE];
        self.write_pos = 0;
    }
}
