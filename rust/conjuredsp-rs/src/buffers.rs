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

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;

    #[test]
    fn test_new_reads_zeros() {
        let dl: DelayLine<64> = DelayLine::new();
        for i in 1..=64 {
            assert_eq!(dl.tap(i), 0.0);
        }
    }

    #[test]
    fn test_write_then_tap1() {
        let mut dl: DelayLine<64> = DelayLine::new();
        dl.write(0.42);
        assert_eq!(dl.tap(1), 0.42);
    }

    #[test]
    fn test_write_n_then_tap_n_wraps() {
        let mut dl: DelayLine<8> = DelayLine::new();
        // Write 8 samples (fills entire buffer), then write 3 more to wrap
        for i in 0..11 {
            dl.write(i as f32);
        }
        // The last sample written was 10.0
        assert_eq!(dl.tap(1), 10.0);
        // 8 samples ago was sample 3.0
        assert_eq!(dl.tap(8), 3.0);
    }

    #[test]
    fn test_read_integer_delay_matches_tap() {
        let mut dl: DelayLine<64> = DelayLine::new();
        for i in 0..20 {
            dl.write(i as f32 * 0.1);
        }
        for delay in 1..=20 {
            let tap_val = dl.tap(delay);
            let read_val = dl.read(delay as f64);
            assert!(
                (tap_val - read_val).abs() < 1e-6,
                "delay={}: tap={} read={}",
                delay,
                tap_val,
                read_val
            );
        }
    }

    #[test]
    fn test_read_fractional_delay_interpolates() {
        let mut dl: DelayLine<64> = DelayLine::new();
        // Write a known sequence: 0, 1, 2, 3, ...
        for i in 0..10 {
            dl.write(i as f32);
        }
        // tap(1) = 9.0, tap(2) = 8.0
        // read(1.5) should interpolate between them: 8.5
        let val = dl.read(1.5);
        assert!(
            (val - 8.5).abs() < 1e-4,
            "fractional read expected 8.5, got {}",
            val
        );
    }

    #[test]
    fn test_read_cubic_integer_delay_matches_tap() {
        let mut dl: DelayLine<64> = DelayLine::new();
        for i in 0..20 {
            dl.write(i as f32 * 0.1);
        }
        for delay in 2..=18 {
            let tap_val = dl.tap(delay);
            let cubic_val = dl.read_cubic(delay as f64);
            assert!(
                (tap_val - cubic_val).abs() < 1e-4,
                "delay={}: tap={} cubic={}",
                delay,
                tap_val,
                cubic_val
            );
        }
    }

    #[test]
    fn test_clear_zeros_everything() {
        let mut dl: DelayLine<16> = DelayLine::new();
        for i in 0..16 {
            dl.write((i + 1) as f32);
        }
        dl.clear();
        for i in 1..=16 {
            assert_eq!(dl.tap(i), 0.0, "tap({}) should be 0 after clear", i);
        }
    }
}
