//! Real-time spectrum analysis.
//!
//! [`Analyzer`] consumes interleaved-free mono samples on the audio thread and produces a
//! log-spaced magnitude curve in dBFS. Everything is pre-allocated at construction, so
//! [`Analyzer::push`] never allocates and never locks.

use std::f32::consts::PI;

use realfft::{RealFftPlanner, RealToComplex};
use std::sync::Arc;

/// Number of samples per FFT. 4096 gives ~11.7 Hz resolution at 48 kHz, which is enough to
/// separate low-mid content where mix "mud" lives.
pub const FFT_SIZE: usize = 4096;

/// Samples between successive FFTs. 1024 → ~47 frames/sec at 48 kHz, comfortably above the
/// display refresh we actually ship over the wire.
pub const HOP_SIZE: usize = 1024;

/// Number of log-spaced display bins in a published spectrum frame.
pub const NUM_BINS: usize = 128;

/// Lowest frequency shown on the graph.
pub const FREQ_MIN: f32 = 20.0;

/// Highest frequency shown on the graph.
pub const FREQ_MAX: f32 = 20_000.0;

/// Magnitude floor. Anything quieter reads as this value.
pub const DB_FLOOR: f32 = -100.0;

/// Centre frequency of display bin `i` (bin centres are geometric, matching the log x-axis).
pub fn bin_frequency(i: usize) -> f32 {
    let t = (i as f32 + 0.5) / NUM_BINS as f32;
    FREQ_MIN * (FREQ_MAX / FREQ_MIN).powf(t)
}

/// Lower edge of display bin `i`.
fn bin_edge(i: usize) -> f32 {
    let t = i as f32 / NUM_BINS as f32;
    FREQ_MIN * (FREQ_MAX / FREQ_MIN).powf(t)
}

/// A single analysis result: `NUM_BINS` magnitudes in dBFS plus broadband levels.
#[derive(Clone, Debug)]
pub struct Spectrum {
    pub bins: [f32; NUM_BINS],
    /// Peak sample magnitude observed over the analysis window, in dBFS.
    pub peak_db: f32,
    /// RMS level over the analysis window, in dBFS.
    pub rms_db: f32,
}

impl Default for Spectrum {
    fn default() -> Self {
        Spectrum {
            bins: [DB_FLOOR; NUM_BINS],
            peak_db: DB_FLOOR,
            rms_db: DB_FLOOR,
        }
    }
}

/// Where a display bin gets its magnitude from.
///
/// Above roughly 200 Hz a display bin is wider than the FFT's resolution, so it covers several
/// FFT bins and we take the loudest — the standard analyzer behaviour, and what makes narrow
/// peaks stay visible. Down at the bottom of the range the opposite is true: a display bin is
/// narrower than one FFT bin, and several neighbouring display bins would otherwise all read
/// the same FFT bin, drawing the low end as a staircase. There we interpolate between adjacent
/// FFT bins instead, which keeps the curve smooth and puts the peak of a tone in the right place.
#[derive(Clone, Copy, Debug, PartialEq)]
enum BinSource {
    /// Take the largest magnitude over the half-open FFT bin range `[start, end)`.
    Max { start: usize, end: usize },
    /// Interpolate between FFT bins `k` and `k + 1` by `frac`.
    Interp { k: usize, frac: f32 },
}

/// Converts a linear amplitude (1.0 == full scale) to dBFS, clamped at [`DB_FLOOR`].
pub fn amp_to_db(amp: f32) -> f32 {
    if amp <= 1e-10 {
        DB_FLOOR
    } else {
        (20.0 * amp.log10()).max(DB_FLOOR)
    }
}

pub struct Analyzer {
    fft: Arc<dyn RealToComplex<f32>>,
    /// Circular buffer holding the most recent `FFT_SIZE` input samples.
    ring: Vec<f32>,
    write: usize,
    /// Samples accumulated since the last FFT.
    since_fft: usize,
    /// Total samples ever written, so we can suppress output until the ring is primed.
    primed: bool,
    filled: usize,

    window: Vec<f32>,
    window_sum: f32,

    scratch_in: Vec<f32>,
    scratch_fft: Vec<realfft::num_complex::Complex<f32>>,
    scratch_work: Vec<realfft::num_complex::Complex<f32>>,

    /// How each display bin draws from the FFT output.
    bin_map: Vec<BinSource>,

    sample_rate: f32,
    /// Smoothed output, held between frames so the release ballistic has memory.
    smoothed: [f32; NUM_BINS],
    release_coeff: f32,

    peak_accum: f32,
    sumsq_accum: f64,
    accum_count: usize,
}

impl Analyzer {
    pub fn new(sample_rate: f32) -> Analyzer {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);

        let scratch_in = fft.make_input_vec();
        let scratch_fft = fft.make_output_vec();
        let scratch_work = fft.make_scratch_vec();

        // Periodic Hann. Sums to FFT_SIZE/2, which is the coherent gain we divide out below.
        let mut window = vec![0.0f32; FFT_SIZE];
        let mut window_sum = 0.0f32;
        for (n, w) in window.iter_mut().enumerate() {
            *w = 0.5 * (1.0 - (2.0 * PI * n as f32 / FFT_SIZE as f32).cos());
            window_sum += *w;
        }

        let mut analyzer = Analyzer {
            fft,
            ring: vec![0.0; FFT_SIZE],
            write: 0,
            since_fft: 0,
            primed: false,
            filled: 0,
            window,
            window_sum,
            scratch_in,
            scratch_fft,
            scratch_work,
            bin_map: vec![BinSource::Max { start: 1, end: 2 }; NUM_BINS],
            sample_rate,
            smoothed: [DB_FLOOR; NUM_BINS],
            release_coeff: 0.0,
            peak_accum: 0.0,
            sumsq_accum: 0.0,
            accum_count: 0,
        };
        analyzer.set_sample_rate(sample_rate);
        analyzer
    }

    /// Recomputes everything that depends on sample rate. Safe to call when the host changes
    /// rate; clears held state so stale bins don't leak across the change.
    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(1.0);
        let hz_per_bin = self.sample_rate / FFT_SIZE as f32;
        let max_fft_bin = FFT_SIZE / 2; // inclusive Nyquist index

        for i in 0..NUM_BINS {
            let f_lo = bin_edge(i);
            let f_hi = bin_edge(i + 1);
            // Decide on the bin's true width, not on rounded indices: rounding `start` down and
            // `end` up makes neighbouring display bins share an FFT bin, and two bins that share
            // the loudest FFT bin report an identical magnitude. A tone then reads as a plateau
            // and its apparent peak lands on whichever end of the plateau you happen to scan
            // last, which is how a 100 Hz tone at 44.1 kHz ended up two bins high.
            let width_in_fft_bins = (f_hi - f_lo) / hz_per_bin;
            let start = (f_lo / hz_per_bin).floor() as isize;
            let end = (f_hi / hz_per_bin).ceil() as isize;

            self.bin_map[i] = if width_in_fft_bins >= 2.0 {
                let start = start.clamp(1, max_fft_bin as isize); // bin 0 is DC, never shown
                let end = end.clamp(start + 1, max_fft_bin as isize + 1);
                BinSource::Max {
                    start: start as usize,
                    end: end as usize,
                }
            } else {
                let pos = bin_frequency(i) / hz_per_bin;
                let k = (pos.floor() as isize).clamp(1, max_fft_bin as isize - 1);
                BinSource::Interp {
                    k: k as usize,
                    frac: (pos - k as f32).clamp(0.0, 1.0),
                }
            };
        }

        // ~350 ms to fall 1/e, expressed per analysis hop.
        let hop_secs = HOP_SIZE as f32 / self.sample_rate;
        self.release_coeff = (-hop_secs / 0.35).exp();

        self.reset();
    }

    pub fn reset(&mut self) {
        self.ring.fill(0.0);
        self.write = 0;
        self.since_fft = 0;
        self.primed = false;
        self.filled = 0;
        self.smoothed = [DB_FLOOR; NUM_BINS];
        self.peak_accum = 0.0;
        self.sumsq_accum = 0.0;
        self.accum_count = 0;
    }

    pub fn sample_rate(&self) -> f32 {
        self.sample_rate
    }

    /// Feeds a block of mono samples. Calls `on_frame` once per completed FFT hop — usually
    /// zero or one time per audio block, but more for very large blocks.
    ///
    /// Audio-thread safe: no allocation, no locking, no syscalls.
    pub fn push(&mut self, samples: &[f32], mut on_frame: impl FnMut(&Spectrum)) {
        for &s in samples {
            self.ring[self.write] = s;
            self.write = (self.write + 1) % FFT_SIZE;

            let a = s.abs();
            if a > self.peak_accum {
                self.peak_accum = a;
            }
            self.sumsq_accum += (s as f64) * (s as f64);
            self.accum_count += 1;

            if !self.primed {
                self.filled += 1;
                if self.filled >= FFT_SIZE {
                    self.primed = true;
                }
            }

            self.since_fft += 1;
            if self.since_fft >= HOP_SIZE {
                self.since_fft = 0;
                if self.primed {
                    let spectrum = self.compute();
                    on_frame(&spectrum);
                }
            }
        }
    }

    fn compute(&mut self) -> Spectrum {
        // Copy the ring out in chronological order, applying the window as we go.
        for n in 0..FFT_SIZE {
            let idx = (self.write + n) % FFT_SIZE;
            self.scratch_in[n] = self.ring[idx] * self.window[n];
        }

        // realfft consumes its input buffer as scratch; that's fine, we refill it every hop.
        let _ = self.fft.process_with_scratch(
            &mut self.scratch_in,
            &mut self.scratch_fft,
            &mut self.scratch_work,
        );

        // A full-scale sine at a bin centre has |X[k]| == A/2 * sum(w), so this normalisation
        // puts such a sine at exactly 0 dBFS.
        let norm = 2.0 / self.window_sum;

        let mag_at = |fft: &[realfft::num_complex::Complex<f32>], k: usize| -> f32 {
            let c = fft[k];
            (c.re * c.re + c.im * c.im).sqrt()
        };

        let mut bins = [DB_FLOOR; NUM_BINS];
        for i in 0..NUM_BINS {
            let amp = match self.bin_map[i] {
                BinSource::Max { start, end } => {
                    let mut peak = 0.0f32;
                    for k in start..end {
                        let mag = mag_at(&self.scratch_fft, k);
                        if mag > peak {
                            peak = mag;
                        }
                    }
                    peak
                }
                BinSource::Interp { k, frac } => {
                    let a = mag_at(&self.scratch_fft, k);
                    let b = mag_at(&self.scratch_fft, k + 1);
                    a + (b - a) * frac
                }
            };
            let db = amp_to_db(amp * norm);

            // Fast attack, exponential release, so transients read immediately but the curve
            // doesn't flicker.
            let prev = self.smoothed[i];
            let out = if db >= prev {
                db
            } else {
                prev + (db - prev) * (1.0 - self.release_coeff)
            };
            self.smoothed[i] = out;
            bins[i] = out;
        }

        let rms = if self.accum_count > 0 {
            (self.sumsq_accum / self.accum_count as f64).sqrt() as f32
        } else {
            0.0
        };
        let spectrum = Spectrum {
            bins,
            peak_db: amp_to_db(self.peak_accum),
            rms_db: amp_to_db(rms),
        };

        self.peak_accum = 0.0;
        self.sumsq_accum = 0.0;
        self.accum_count = 0;

        spectrum
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, amp: f32, n: usize, sr: f32) -> Vec<f32> {
        (0..n)
            .map(|i| amp * (2.0 * PI * freq * i as f32 / sr).sin())
            .collect()
    }

    /// Runs the analyzer over `samples` and returns the last emitted spectrum.
    fn analyze(samples: &[f32], sr: f32) -> Spectrum {
        let mut a = Analyzer::new(sr);
        let mut last = None;
        a.push(samples, |s| last = Some(s.clone()));
        last.expect("analyzer produced no frame")
    }

    fn nearest_bin(freq: f32) -> usize {
        (0..NUM_BINS)
            .min_by(|&a, &b| {
                (bin_frequency(a) - freq)
                    .abs()
                    .partial_cmp(&(bin_frequency(b) - freq).abs())
                    .unwrap()
            })
            .unwrap()
    }

    #[test]
    fn silence_reads_at_the_floor() {
        let s = analyze(&vec![0.0; FFT_SIZE * 3], 48_000.0);
        for (i, &db) in s.bins.iter().enumerate() {
            assert_eq!(db, DB_FLOOR, "bin {i} should be at the floor");
        }
        assert_eq!(s.peak_db, DB_FLOOR);
    }

    /// A tone rarely lands exactly on an FFT bin centre, and a Hann window under-reads a
    /// worst-case half-bin-offset tone by 1.42 dB. That scalloping loss is inherent to reading
    /// peak magnitude off an FFT, so the level assertions allow for it.
    const SCALLOP_TOLERANCE_DB: f32 = 1.5;

    #[test]
    fn full_scale_sine_reads_zero_dbfs() {
        let sr = 48_000.0;
        let s = analyze(&sine(1000.0, 1.0, FFT_SIZE * 4, sr), sr);
        let bin = nearest_bin(1000.0);
        assert!(
            s.bins[bin].abs() < SCALLOP_TOLERANCE_DB,
            "1 kHz full-scale sine should read ~0 dBFS, got {} at bin {bin}",
            s.bins[bin]
        );
    }

    #[test]
    fn sine_level_tracks_amplitude() {
        let sr = 48_000.0;
        for (amp, expect) in [(1.0f32, 0.0f32), (0.1, -20.0), (0.01, -40.0)] {
            let s = analyze(&sine(1000.0, amp, FFT_SIZE * 4, sr), sr);
            let bin = nearest_bin(1000.0);
            assert!(
                (s.bins[bin] - expect).abs() < SCALLOP_TOLERANCE_DB,
                "amp {amp} should read ~{expect} dBFS, got {}",
                s.bins[bin]
            );
        }
    }

    /// Level accuracy has to hold on the interpolating path too, not just the max path.
    #[test]
    fn low_frequency_tone_level_is_accurate() {
        let sr = 48_000.0;
        for freq in [40.0f32, 60.0, 100.0, 150.0] {
            let s = analyze(&sine(freq, 0.5, FFT_SIZE * 6, sr), sr);
            let bin = nearest_bin(freq);
            let expect = -6.02;
            assert!(
                (s.bins[bin] - expect).abs() < SCALLOP_TOLERANCE_DB,
                "{freq} Hz at -6 dBFS read {} at bin {bin}",
                s.bins[bin]
            );
        }
    }

    #[test]
    fn energy_is_localised_around_the_tone() {
        let sr = 48_000.0;
        let s = analyze(&sine(1000.0, 1.0, FFT_SIZE * 4, sr), sr);
        let bin = nearest_bin(1000.0);
        // Two octaves below the tone there should be essentially nothing.
        let far = nearest_bin(250.0);
        assert!(
            s.bins[bin] - s.bins[far] > 40.0,
            "expected >40 dB between tone bin ({}) and 250 Hz ({})",
            s.bins[bin],
            s.bins[far]
        );
    }

    #[test]
    fn broadband_levels_are_reported() {
        let sr = 48_000.0;
        let s = analyze(&sine(1000.0, 1.0, FFT_SIZE * 4, sr), sr);
        assert!(
            (s.peak_db - 0.0).abs() < 0.5,
            "peak of a full-scale sine should be ~0 dBFS, got {}",
            s.peak_db
        );
        // RMS of a sine is amplitude/sqrt(2) == -3.01 dBFS.
        assert!(
            (s.rms_db + 3.01).abs() < 0.5,
            "RMS of a full-scale sine should be ~-3 dBFS, got {}",
            s.rms_db
        );
    }

    #[test]
    fn bins_release_after_signal_stops() {
        let sr = 48_000.0;
        let mut a = Analyzer::new(sr);
        let bin = nearest_bin(1000.0);

        let mut loud = DB_FLOOR;
        a.push(&sine(1000.0, 1.0, FFT_SIZE * 4, sr), |s| loud = s.bins[bin]);
        assert!(loud > -3.0, "tone should be loud, got {loud}");

        let mut quiet = DB_FLOOR;
        a.push(&vec![0.0; FFT_SIZE * 4], |s| quiet = s.bins[bin]);
        assert!(
            quiet < loud - 10.0,
            "bin should have released: loud {loud}, quiet {quiet}"
        );
    }

    #[test]
    fn no_frames_emitted_until_the_window_is_primed() {
        let mut a = Analyzer::new(48_000.0);
        let mut frames = 0;
        // One hop short of a full window: the ring isn't primed, so nothing should be emitted.
        a.push(&vec![0.5; FFT_SIZE - HOP_SIZE], |_| frames += 1);
        assert_eq!(frames, 0);
        a.push(&vec![0.5; HOP_SIZE], |_| frames += 1);
        assert_eq!(frames, 1);
    }

    #[test]
    fn frame_rate_matches_hop_size() {
        let mut a = Analyzer::new(48_000.0);
        a.push(&vec![0.0; FFT_SIZE], |_| {});
        let mut frames = 0;
        a.push(&vec![0.0; HOP_SIZE * 10], |_| frames += 1);
        assert_eq!(frames, 10);
    }

    #[test]
    fn block_size_does_not_change_results() {
        let sr = 48_000.0;
        let signal = sine(1000.0, 0.5, FFT_SIZE * 4, sr);

        let one_shot = analyze(&signal, sr);

        let mut a = Analyzer::new(sr);
        let mut chunked = None;
        for chunk in signal.chunks(37) {
            a.push(chunk, |s| chunked = Some(s.clone()));
        }
        let chunked = chunked.unwrap();

        for i in 0..NUM_BINS {
            assert!(
                (one_shot.bins[i] - chunked.bins[i]).abs() < 1e-3,
                "bin {i} differs between block sizes: {} vs {}",
                one_shot.bins[i],
                chunked.bins[i]
            );
        }
    }

    #[test]
    fn bin_frequencies_span_the_audible_range_monotonically() {
        for i in 1..NUM_BINS {
            assert!(bin_frequency(i) > bin_frequency(i - 1));
        }
        assert!(bin_frequency(0) >= FREQ_MIN);
        assert!(bin_frequency(NUM_BINS - 1) <= FREQ_MAX);
    }

    #[test]
    fn every_display_bin_reads_a_valid_fft_bin() {
        for sr in [44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let a = Analyzer::new(sr);
            for (i, src) in a.bin_map.iter().enumerate() {
                match *src {
                    BinSource::Max { start, end } => {
                        assert!(start >= 1, "bin {i} reads DC at {sr} Hz");
                        assert!(end > start, "bin {i} is empty at {sr} Hz");
                        assert!(end <= FFT_SIZE / 2 + 1, "bin {i} runs past Nyquist at {sr} Hz");
                    }
                    BinSource::Interp { k, frac } => {
                        assert!(k >= 1, "bin {i} interpolates from DC at {sr} Hz");
                        assert!(k + 1 <= FFT_SIZE / 2, "bin {i} runs past Nyquist at {sr} Hz");
                        assert!((0.0..=1.0).contains(&frac), "bin {i} frac {frac} out of range");
                    }
                }
            }
        }
    }

    /// The low end is the case that drove the interpolating path: below a couple of hundred
    /// hertz a display bin is narrower than one FFT bin, and a naive mapping makes several
    /// neighbours read the identical FFT bin.
    #[test]
    fn low_end_does_not_stair_step() {
        let a = Analyzer::new(48_000.0);
        let low: Vec<_> = (0..24).map(|i| a.bin_map[i]).collect();
        for w in low.windows(2) {
            assert_ne!(
                w[0], w[1],
                "neighbouring low bins resolve identically, the curve would stair-step"
            );
        }
    }

    #[test]
    fn tone_lands_in_the_right_bin_at_several_sample_rates() {
        for sr in [44_100.0f32, 48_000.0, 96_000.0] {
            for freq in [100.0f32, 1000.0, 5000.0] {
                let s = analyze(&sine(freq, 1.0, FFT_SIZE * 4, sr), sr);
                let expected = nearest_bin(freq);
                let loudest = (0..NUM_BINS)
                    .max_by(|&a, &b| s.bins[a].partial_cmp(&s.bins[b]).unwrap())
                    .unwrap();
                assert!(
                    (loudest as isize - expected as isize).abs() <= 1,
                    "at {sr} Hz a {freq} Hz tone peaked at bin {loudest}, expected ~{expected}"
                );
            }
        }
    }
}
