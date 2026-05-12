use core::f64::consts::PI;

/// LFO waveform type.
#[derive(Clone, Copy)]
pub enum Waveform {
    Sine,
    Triangle,
    Saw,
    Square,
}

/// Low-frequency oscillator with multiple waveforms.
///
/// Maintains phase across callbacks via `persist!` (Lfo is `Copy`, so the
/// `.get()` / `.set()` round-trip is cheap):
///
/// ```ignore
/// persist!(LFO_STATE: Lfo = Lfo::new());
///
/// // Inside process! { ctx => … }:
/// let mut lfo = LFO_STATE.get();
/// lfo.init(ctx.sample_rate() as f64, rate_hz);
/// for i in 0..ctx.frames() {
///     let mod_val = lfo.tick();
///     // use mod_val
/// }
/// LFO_STATE.set(lfo);
/// ```
#[derive(Clone, Copy)]
pub struct Lfo {
    phase: f64,
    freq: f64,
    sample_rate: f64,
    waveform: Waveform,
    /// Current oscillator value (updated by `tick()`).
    pub value: f64,
}

impl Lfo {
    /// Create an LFO with default settings (1 Hz sine, 44100 Hz sample rate).
    pub const fn new() -> Self {
        Lfo {
            phase: 0.0,
            freq: 1.0,
            sample_rate: 44100.0,
            waveform: Waveform::Sine,
            value: 0.0,
        }
    }

    /// Set sample rate and frequency. Call at the start of each process() callback.
    #[inline]
    pub fn init(&mut self, sample_rate: f64, freq: f64) {
        self.sample_rate = sample_rate;
        self.freq = freq;
    }

    /// Update the oscillation frequency.
    #[inline]
    pub fn set_freq(&mut self, freq: f64) {
        self.freq = freq;
    }

    /// Change the waveform type.
    #[inline]
    pub fn set_waveform(&mut self, waveform: Waveform) {
        self.waveform = waveform;
    }

    /// Advance by one sample and return the current value in \[-1, 1\].
    #[inline]
    pub fn tick(&mut self) -> f64 {
        let p = self.phase;
        self.value = match self.waveform {
            Waveform::Sine => (2.0 * PI * p).sin(),
            Waveform::Triangle => 4.0 * (p - 0.5).abs() - 1.0,
            Waveform::Saw => 2.0 * p - 1.0,
            Waveform::Square => {
                if p < 0.5 {
                    1.0
                } else {
                    -1.0
                }
            }
        };
        self.phase = (p + self.freq / self.sample_rate) % 1.0;
        self.value
    }

    /// Advance by `n` samples, writing values into `out[..n]`.
    ///
    /// Equivalent to calling `tick()` in a loop but mirrors the Python
    /// `tick_n()` API for parity.
    pub fn tick_n(&mut self, out: &mut [f64], n: usize) {
        let len = if n < out.len() { n } else { out.len() };
        for i in 0..len {
            out[i] = self.tick();
        }
    }

    /// Reset phase to zero.
    pub fn reset(&mut self) {
        self.phase = 0.0;
        self.value = 0.0;
    }
}

/// Compute sin(2*pi*phase). Phase in \[0, 1), output in \[-1, 1\].
#[inline]
pub fn sine(phase: f64) -> f64 {
    (2.0 * PI * phase).sin()
}

/// Triangle wave from phase \[0, 1). Output in \[-1, 1\].
#[inline]
pub fn triangle(phase: f64) -> f64 {
    4.0 * (phase - 0.5).abs() - 1.0
}

/// Sawtooth wave from phase \[0, 1). Output in \[-1, 1\].
#[inline]
pub fn saw(phase: f64) -> f64 {
    2.0 * phase - 1.0
}

/// Advance phase by one sample, wrapping at 1.0.
#[inline]
pub fn advance_phase(phase: f64, freq: f64, sample_rate: f64) -> f64 {
    (phase + freq / sample_rate) % 1.0
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;

    fn approx_eq(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    // sine tests
    #[test]
    fn test_sine_0() {
        assert!(approx_eq(sine(0.0), 0.0, 1e-10));
    }

    #[test]
    fn test_sine_quarter() {
        assert!(approx_eq(sine(0.25), 1.0, 1e-10));
    }

    #[test]
    fn test_sine_half() {
        assert!(approx_eq(sine(0.5), 0.0, 1e-10));
    }

    #[test]
    fn test_sine_three_quarter() {
        assert!(approx_eq(sine(0.75), -1.0, 1e-10));
    }

    // triangle tests
    #[test]
    fn test_triangle_0() {
        // 4.0 * |0.0 - 0.5| - 1.0 = 4.0 * 0.5 - 1.0 = 1.0
        assert!(approx_eq(triangle(0.0), 1.0, 1e-10));
    }

    #[test]
    fn test_triangle_quarter() {
        // 4.0 * |0.25 - 0.5| - 1.0 = 4.0 * 0.25 - 1.0 = 0.0
        assert!(approx_eq(triangle(0.25), 0.0, 1e-10));
    }

    #[test]
    fn test_triangle_half() {
        // 4.0 * |0.5 - 0.5| - 1.0 = -1.0
        assert!(approx_eq(triangle(0.5), -1.0, 1e-10));
    }

    // saw tests
    #[test]
    fn test_saw_0() {
        assert!(approx_eq(saw(0.0), -1.0, 1e-10));
    }

    #[test]
    fn test_saw_half() {
        assert!(approx_eq(saw(0.5), 0.0, 1e-10));
    }

    #[test]
    fn test_saw_near_1() {
        assert!(approx_eq(saw(0.999), 0.998, 1e-4));
    }

    // Lfo tests
    #[test]
    fn test_lfo_defaults() {
        let lfo = Lfo::new();
        assert_eq!(lfo.value, 0.0);
        assert_eq!(lfo.freq, 1.0);
    }

    #[test]
    fn test_lfo_phase_wraps_after_one_cycle() {
        let mut lfo = Lfo::new();
        lfo.init(44100.0, 1.0);
        for _ in 0..44100 {
            lfo.tick();
        }
        // After exactly one cycle at 1 Hz, phase should wrap back near 0
        // We can't read phase directly, but the value at phase≈0 for sine should be ≈0
        let val = lfo.tick();
        assert!(
            val.abs() < 0.001,
            "after full cycle, sine LFO should be near 0, got {}",
            val
        );
    }

    #[test]
    fn test_lfo_reset() {
        let mut lfo = Lfo::new();
        lfo.init(44100.0, 1.0);
        for _ in 0..1000 {
            lfo.tick();
        }
        lfo.reset();
        assert_eq!(lfo.value, 0.0);
        // First tick after reset at phase=0 for sine should give sin(0) = 0
        let val = lfo.tick();
        assert!(approx_eq(val, 0.0, 1e-10));
    }

    #[test]
    fn test_lfo_set_freq() {
        let mut lfo = Lfo::new();
        lfo.init(44100.0, 1.0);
        lfo.set_freq(10.0);
        // After 4410 ticks at 10 Hz / 44100 SR, we complete one cycle
        for _ in 0..4410 {
            lfo.tick();
        }
        let val = lfo.tick();
        assert!(
            val.abs() < 0.01,
            "after full cycle at 10Hz, sine should be near 0, got {}",
            val
        );
    }

    #[test]
    fn test_lfo_set_waveform() {
        let mut lfo = Lfo::new();
        lfo.init(44100.0, 1.0);
        lfo.set_waveform(Waveform::Square);
        // First tick at phase=0 for square (phase < 0.5) should be 1.0
        let val = lfo.tick();
        assert!(approx_eq(val, 1.0, 1e-10));
    }

    #[test]
    fn test_lfo_tick_n_matches_tick_loop() {
        // tick_n should produce identical results to calling tick() in a loop
        let mut lfo_a = Lfo::new();
        lfo_a.init(44100.0, 440.0);
        let mut lfo_b = Lfo::new();
        lfo_b.init(44100.0, 440.0);

        let n = 128;
        let mut buf_a = [0.0f64; 128];
        for i in 0..n {
            buf_a[i] = lfo_a.tick();
        }

        let mut buf_b = [0.0f64; 128];
        lfo_b.tick_n(&mut buf_b, n);

        for i in 0..n {
            assert!(
                approx_eq(buf_a[i], buf_b[i], 1e-15),
                "mismatch at sample {}: tick()={} tick_n()={}",
                i, buf_a[i], buf_b[i]
            );
        }
        // Phase should be identical after both
        let val_a = lfo_a.tick();
        let val_b = lfo_b.tick();
        assert!(approx_eq(val_a, val_b, 1e-15));
    }

    // advance_phase tests
    #[test]
    fn test_advance_phase_basic() {
        let phase = advance_phase(0.0, 440.0, 44100.0);
        assert!(approx_eq(phase, 440.0 / 44100.0, 1e-10));
    }

    #[test]
    fn test_advance_phase_wraps() {
        let phase = advance_phase(0.999, 440.0, 44100.0);
        // 0.999 + 440/44100 ≈ 1.0089... should wrap to ≈ 0.0089
        assert!(phase < 1.0, "phase should wrap at 1.0, got {}", phase);
        assert!(phase >= 0.0);
    }
}
