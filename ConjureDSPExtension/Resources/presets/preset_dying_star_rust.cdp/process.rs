// Dying Star — kick → dying star collapsing into a black hole.
//
// Sub-bass rumble bus (rectify → 80 Hz LP) → gravitational redshift dual-tap
// pitch shifter → 4 cascaded Schroeder allpass diffusers (dispersion lensing)
// → closing one-pole lowpass (collapse-controlled cutoff) → Schwarzschild
// resonance bandpass at 110 Hz → event-horizon bit reduction → final mix.
//
// Params:
//   COLLAPSE      (pct)    — closes lowpass cutoff + drives bit reduction
//   GRAVITY       (pct)    — pitch-shift drift rate (Free mode only)
//   SUB           (pct)    — rumble bus level
//   MIX                    — wet/dry blend
//   GRAVITY_SYNC  (choice) — lock pitch-shift grain phase to host beat
//   COLLAPSE_SYNC (choice) — beat-locked decay envelope on the closing lowpass

use conjuredsp::*;
setup!();

const SYNC_LABELS: &[&str] = &["Free", "1/16", "1/8", "1/4", "1/2", "1 bar", "2 bars"];

params! {
    COLLAPSE = pct().default(55.0),
    GRAVITY = pct().default(60.0),
    SUB = pct().default(70.0),
    MIX = mix().default(0.6),
    GRAVITY_SYNC = choice(SYNC_LABELS),
    COLLAPSE_SYNC = choice(SYNC_LABELS),
}

// Sync index → quarter-note beats. 0.0 means "computed at runtime from
// the host's time signature numerator" (1 bar = num quarter notes).
const SYNC_DIVISIONS: [f64; 7] = [0.0, 0.25, 0.5, 1.0, 2.0, 0.0, 0.0];

#[inline]
fn resolve_sync(idx: usize, time_sig_num: f64) -> f64 {
    if idx == 0 || idx >= SYNC_DIVISIONS.len() {
        return 0.0;
    }
    let preset = SYNC_DIVISIONS[idx];
    if preset > 0.0 {
        return preset;
    }
    let bar = if time_sig_num > 0.0 { time_sig_num } else { 4.0 };
    if idx == 5 { bar } else { 2.0 * bar }
}

const MAX_DL: usize = 24000;

const SHIFT_BASE_MS: f64 = 50.0;
const GRAIN_MS: f64 = 80.0;
const AP_MS: [f64; 4] = [11.3, 17.7, 23.1, 29.9];
const AP_G: f64 = 0.65;

static mut SUB_LP: [Biquad; 2] = [Biquad::new(); 2];
static mut SHIFT_DL: [DelayLine<MAX_DL>; 2] = [DelayLine::new(); 2];
static mut AP: [[DelayLine<MAX_DL>; 4]; 2] = [[DelayLine::new(); 4]; 2];
static mut APS: [[f64; 4]; 2] = [[0.0; 4]; 2];
static mut CLOSE_LP: [f64; 2] = [0.0; 2];
static mut RING: [Biquad; 2] = [Biquad::new(); 2];
static mut GRAIN_PHASE: f64 = 0.0;

#[no_mangle]
pub extern "C" fn process(
    input: *const f32, output: *mut f32,
    channels: i32, frame_count: i32, sample_rate: f32,
) {
    let ctx = ctx(input, output, channels, frame_count, sample_rate);
    let sr = ctx.sample_rate() as f64;

    unsafe {
        let collapse = ctx.param(COLLAPSE) as f64 / 100.0;
        let gravity = ctx.param(GRAVITY) as f64 / 100.0;
        let sub = ctx.param(SUB) as f64 / 100.0;
        let mx = ctx.param(MIX) as f64;

        // Host transport for beat-locked sync. If the host isn't playing or has
        // no tempo, both sync modes fall back to free-running so the preset still
        // works in auval and stopped DAWs.
        let tempo = TRANSPORT_BUF[T_TEMPO] as f64;
        let beat = TRANSPORT_BUF[T_BEAT] as f64;
        let playing = TRANSPORT_BUF[T_PLAYING] as f64 >= 0.5;
        let time_sig_num = TRANSPORT_BUF[T_TIME_SIG_NUM] as f64;
        let sync_active = playing && tempo > 0.0;
        let beats_per_sample = if sync_active { (tempo / 60.0) / sr } else { 0.0 };

        let grav_div = if sync_active {
            resolve_sync(ctx.param(GRAVITY_SYNC).round() as usize, time_sig_num)
        } else {
            0.0
        };
        let coll_div = if sync_active {
            resolve_sync(ctx.param(COLLAPSE_SYNC).round() as usize, time_sig_num)
        } else {
            0.0
        };
        let grav_synced = grav_div > 0.0;
        let coll_synced = coll_div > 0.0;

        // Sub-bass lowpass coefficients (80 Hz Q=0.7)
        let sub_lpc = BiquadCoeffs::lowpass(80.0, 0.707, sr);
        // Schwarzschild ringing bandpass at 110 Hz, Q=18
        let ringc = BiquadCoeffs::bandpass(110.0, 18.0, sr);
        let nch = ctx.channels().min(2);
        for ch in 0..nch {
            SUB_LP[ch].set_coeffs(sub_lpc);
            RING[ch].set_coeffs(ringc);
        }

        // Closing lowpass: cutoff sweeps from 8000 Hz (collapse=0) to 350 Hz (collapse=1)
        let close_fc = 8000.0 - 7650.0 * collapse;
        let close_alpha = (-2.0 * core::f64::consts::PI * close_fc / sr).exp();
        let close_one_minus = 1.0 - close_alpha;

        // Pitch shifter
        let base_d = SHIFT_BASE_MS * 0.001 * sr;
        let grain_samples = GRAIN_MS * 0.001 * sr;
        let grain_rate = (0.4 + 1.6 * gravity) / grain_samples;

        // Bit reduction: 8 bits at collapse=0, 2 bits at collapse=1
        let bits = 8.0 - 6.0 * collapse;
        let levels = (2.0_f64).powf(bits);
        let inv_levels = 1.0 / levels;

        // Allpass times in samples
        let ap_d: [f64; 4] = [
            (AP_MS[0] * 0.001 * sr).max(1.0),
            (AP_MS[1] * 0.001 * sr).max(1.0),
            (AP_MS[2] * 0.001 * sr).max(1.0),
            (AP_MS[3] * 0.001 * sr).max(1.0),
        ];

        let rumble_gain = sub * 1.5;
        let ring_gain: f64 = 0.4;

        for f in 0..ctx.frames() {
            // Pitch-shifter grain phase: free-running by default, beat-locked when synced.
            let ph0 = if grav_synced {
                let beat_now = beat + f as f64 * beats_per_sample;
                let p = (beat_now / grav_div) % 1.0;
                if p < 0.0 { p + 1.0 } else { p }
            } else {
                let p = GRAIN_PHASE;
                GRAIN_PHASE = (GRAIN_PHASE + grain_rate) % 1.0;
                p
            };
            let ph1 = (ph0 + 0.5) % 1.0;
            let w0_ = (core::f64::consts::PI * ph0).sin();
            let w0 = w0_ * w0_;
            let w1_ = (core::f64::consts::PI * ph1).sin();
            let w1 = w1_ * w1_;
            let read0 = base_d + ph0 * grain_samples;
            let read1 = base_d + ph1 * grain_samples;

            // Closing-lowpass coefficients: per-buffer in Free mode, per-sample
            // when collapse is beat-pulsed. Bit reduction stays tied to the static collapse.
            let (cur_close_alpha, cur_close_one_minus) = if coll_synced {
                let beat_now = beat + f as f64 * beats_per_sample;
                let mut pulse_phase = (beat_now / coll_div) % 1.0;
                if pulse_phase < 0.0 { pulse_phase += 1.0; }
                let pulse_env = (-3.0 * pulse_phase).exp();
                let mut eff_collapse = collapse + (1.0 - collapse) * pulse_env;
                if eff_collapse > 1.0 { eff_collapse = 1.0; }
                let cur_close_fc = 8000.0 - 7650.0 * eff_collapse;
                let a = (-2.0 * core::f64::consts::PI * cur_close_fc / sr).exp();
                (a, 1.0 - a)
            } else {
                (close_alpha, close_one_minus)
            };

            for ch in 0..nch {
                let dry = ctx.input(ch, f) as f64;

                // Stage A: sub-bass rumble bus (rectify → LP → gain)
                let rectified = dry.abs();
                let rumble = SUB_LP[ch].process_sample(rectified) * rumble_gain;

                // Stage B: gravitational redshift pitch shift (dual-tap crossfade)
                SHIFT_DL[ch].write(dry as f32);
                let g0 = SHIFT_DL[ch].read(read0) as f64;
                let g1 = SHIFT_DL[ch].read(read1) as f64;
                let shifted = w0 * g0 + w1 * g1;

                // Stage C: 4 cascaded Schroeder allpass diffusers (lensing)
                let mut sig = shifted;
                for k in 0..4 {
                    let vd = APS[ch][k];
                    let vn = sig + AP_G * vd;
                    AP[ch][k].write(vn as f32);
                    APS[ch][k] = AP[ch][k].read(ap_d[k]) as f64;
                    sig = vd - AP_G * vn;
                }

                // Stage D: closing one-pole lowpass
                CLOSE_LP[ch] = cur_close_alpha * CLOSE_LP[ch] + cur_close_one_minus * sig;
                let closed = CLOSE_LP[ch];

                // Stage E: Schwarzschild resonance bandpass (parallel)
                let ringing = RING[ch].process_sample(closed) * ring_gain;

                // Stage F: event-horizon bit reduction on the closed bus
                let crushed = (closed * levels + 0.5).floor() * inv_levels;

                // Stage G: final wet sum + mix
                let wet = rumble + crushed + ringing;
                ctx.set_output(ch, f, (dry * (1.0 - mx) + wet * mx) as f32);
            }
        }
    }
}
