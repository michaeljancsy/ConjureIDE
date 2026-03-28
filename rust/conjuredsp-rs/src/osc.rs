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
/// Maintains phase across `process()` callbacks. Store in `static mut`.
///
/// ```ignore
/// static mut LFO: Lfo = Lfo::new();
///
/// // In process():
/// unsafe {
///     LFO.init(sample_rate as f64, rate_hz);
///     for i in 0..frames {
///         let mod_val = LFO.tick();
///         // use mod_val
///     }
/// }
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
