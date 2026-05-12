// Mockingbird at Night — a lone nocturnal mimic.
//
// Continuously records input into a ring buffer. Every few seconds it grabs
// the recent audio as a "grain", pitch-shifts it upward (smaller throat,
// bird-like), plays it through a chirp envelope a few times in quick
// succession — the mockingbird's signature repeated-phrase habit — then
// falls silent for a while. Bandpass shapes the bird's voice, long diffuse
// reverb opens the night air around it, faint high-band noise suggests
// insects and distance. Input itself is rarely heard directly — only as
// the mockingbird's interpretation of it.

use conjuredsp::*;
params! {
    DENSITY   = pct().default(40.0),                     // how often it speaks
    PITCH     = pct().default(55.0),                     // how high it mimics
    PITCH_VAR = pct().default(25.0),                     // variation between repeats
    SYLL_MS   = time_ms().min(80.0).max(500.0).default(220.0),
    REPEATS   = pct().default(45.0),                     // syllables per phrase
    TONE      = freq().min(800.0).max(6000.0).default(2800.0),
    REVERB    = mix().default(0.65),                     // night-air ambience
    NIGHT     = mix().default(0.18),                     // insect/noise bed
    WET       = mix().default(1.0),
}

const N_CHANS:    usize = 2;
const REC_SIZE:   usize = 96000;                         // ≥2 s @ 48 k
const GRAIN_SIZE: usize = 48000;                         // ≤1 s captured phrase
const REV_SIZE:   usize = 16384;                         // ≥170 ms @ 96 k

persist_buf!(RECORD: [DelayLine<REC_SIZE>; N_CHANS] = [DelayLine::new(); N_CHANS]);
persist_buf!(GRAIN:  [f32; GRAIN_SIZE] = [0.0; GRAIN_SIZE]);

// ── State machine ───────────────────────────────────────────────────────
#[derive(Copy, Clone, PartialEq)]
enum BirdState { Waiting, Sounding, Gap }

persist!(BIRD_STATE:     BirdState = BirdState::Waiting);
persist!(STATE_REMAIN:   u32 = 48000);                  // samples left in state
persist!(REPEATS_LEFT:   u32 = 0);                      // remaining syllables in phrase
persist!(SYLL_LEN:       u32 = 0);                      // grain length in samples
persist!(PLAY_DURATION:  u32 = 0);                      // output samples for current syllable
persist!(PLAY_POS:       f64 = 0.0);                    // fractional read position in GRAIN
persist!(PLAY_RATE:      f64 = 1.5);                    // current pitch ratio
persist!(BASE_RATE:      f64 = 1.5);                    // phrase-level base rate

// ── Filters ─────────────────────────────────────────────────────────────
persist_buf!(BP:       [Biquad; N_CHANS] = [Biquad::new(); N_CHANS]);
persist_buf!(NIGHT_HP: [Biquad; N_CHANS] = [Biquad::new(); N_CHANS]);
persist_buf!(NIGHT_LP: [Biquad; N_CHANS] = [Biquad::new(); N_CHANS]);

// ── Reverb: 2 combs + 1 allpass per channel, different tunings for stereo ──
const N_COMBS: usize = 2;
const COMB_MS: [[f64; N_COMBS]; N_CHANS] = [[71.0, 113.0], [97.0, 149.0]];
const AP_MS:   [f64; N_CHANS] = [5.3, 7.1];
persist_buf!(COMBS: [[DelayLine<REV_SIZE>; N_COMBS]; N_CHANS] =
    [[DelayLine::new(); N_COMBS]; N_CHANS]);
persist_buf!(AP:    [DelayLine<REV_SIZE>; N_CHANS] = [DelayLine::new(); N_CHANS]);

persist!(RNG: u32 = 0xC0DE_F00D);

#[inline]
fn rand_f(rng: &mut u32) -> f32 {
    *rng ^= *rng << 13;
    *rng ^= *rng >> 17;
    *rng ^= *rng << 5;
    (*rng as f32) / 4_294_967_296.0f32                    // [0, 1)
}

#[inline]
fn rand_bi(rng: &mut u32) -> f32 { rand_f(rng) * 2.0 - 1.0 }

#[inline]
fn grain_read(grain: &[f32; GRAIN_SIZE], pos: f64, len: u32) -> f32 {
    let maxp = (len as f64) - 1.0;
    let p = if pos < 0.0 { 0.0 } else if pos > maxp { maxp } else { pos };
    let i = p as usize;
    let frac = (p - i as f64) as f32;
    let a = grain[i];
    let b = if i + 1 < len as usize { grain[i + 1] } else { a };
    a * (1.0 - frac) + b * frac
}

#[inline]
fn syllable_env(pos: u32, total: u32) -> f32 {
    if total == 0 { return 0.0; }
    let t = pos as f32 / total as f32;
    // Quick attack, slower release — a bird chirp shape.
    let atk = 0.08;
    let rel = 0.45;
    if t < atk {
        let p = t / atk;
        p * p * (3.0 - 2.0 * p)                          // smoothstep ease-in
    } else if t > 1.0 - rel {
        let p = ((1.0 - t) / rel).max(0.0);
        p * p * (3.0 - 2.0 * p)
    } else {
        1.0
    }
}

process! { ctx =>
    let sr = ctx.sample_rate() as f64;

    let density     = (ctx.param(DENSITY) / 100.0).clamp(0.0, 1.0) as f64;
    let pitch_range = (ctx.param(PITCH) / 100.0 * 1.5) as f64;      // 0..1.5 above 1×
    let pitch_var   = (ctx.param(PITCH_VAR) / 100.0 * 0.3) as f64;  // ±0..30 %
    let syll_ms     = ctx.param(SYLL_MS) as f64;
    let repeats_p   = (ctx.param(REPEATS) / 100.0).clamp(0.0, 1.0);
    let tone        = ctx.param(TONE) as f64;
    let rev_amt     = ctx.param(REVERB);
    let night_amt   = ctx.param(NIGHT);
    let wet         = ctx.param(WET);

    let syll_samples = (syll_ms * 0.001 * sr) as u32;
    let pause_min = 0.4 * sr;
    let pause_max = pause_min + (1.0 - density) * 5.0 * sr;
    let gap_min = 0.04 * sr;
    let gap_max = 0.16 * sr;

    let bp_c  = BiquadCoeffs::bandpass(tone, 1.6, sr);
    let nhp_c = BiquadCoeffs::highpass(4500.0, 0.707, sr);
    let nlp_c = BiquadCoeffs::lowpass(10000.0, 0.707, sr);

    let rev_fb = 0.55 + (rev_amt as f32) * 0.40;         // 0.55 → 0.95

    let mut bird_state = BIRD_STATE.get();
    let mut state_remain = STATE_REMAIN.get();
    let mut repeats_left = REPEATS_LEFT.get();
    let mut syll_len = SYLL_LEN.get();
    let mut play_duration = PLAY_DURATION.get();
    let mut play_pos = PLAY_POS.get();
    let mut play_rate = PLAY_RATE.get();
    let mut base_rate = BASE_RATE.get();
    let mut rng = RNG.get();

    RECORD.with_mut(|record| {
        GRAIN.with_mut(|grain| {
            BP.with_mut(|bp| {
                NIGHT_HP.with_mut(|night_hp| {
                    NIGHT_LP.with_mut(|night_lp| {
                        COMBS.with_mut(|combs| {
                            AP.with_mut(|ap| {
                                for c in 0..N_CHANS {
                                    bp[c].set_coeffs(bp_c);
                                    night_hp[c].set_coeffs(nhp_c);
                                    night_lp[c].set_coeffs(nlp_c);
                                }

                                let n_ch = ctx.channels().min(N_CHANS);

                                for f in 0..ctx.frames() {
                                    // Always record input — the bird's memory of what it just heard
                                    for c in 0..n_ch {
                                        record[c].write(ctx.input(c, f));
                                    }

                                    // Advance state machine (once per frame)
                                    let mut bird_mono = 0.0_f32;
                                    match bird_state {
                                        BirdState::Waiting => {
                                            if state_remain == 0 {
                                                // ── Start new phrase ──
                                                let vary = 1.0 + rand_bi(&mut rng) * 0.3;
                                                let mut sl = (syll_samples as f32 * vary) as u32;
                                                if sl < 128 { sl = 128; }
                                                if sl > GRAIN_SIZE as u32 { sl = GRAIN_SIZE as u32; }
                                                syll_len = sl;

                                                // Capture recent audio as mono grain
                                                let n = sl as usize;
                                                for i in 0..n {
                                                    let delay = n - i;
                                                    grain[i] = (record[0].tap(delay) + record[1].tap(delay)) * 0.5;
                                                }

                                                base_rate = 1.0 + rand_f(&mut rng) as f64 * pitch_range;
                                                play_rate = base_rate * (1.0 + rand_bi(&mut rng) as f64 * pitch_var);
                                                play_pos = 0.0;

                                                let rep_max = 1 + (repeats_p * 5.0) as u32;          // up to 6
                                                let total_rep = 1 + (rand_f(&mut rng) * rep_max as f32) as u32;
                                                repeats_left = total_rep - 1;                        // this one is the first

                                                let pd = (syll_len as f64 / play_rate) as u32;
                                                play_duration = if pd == 0 { 1 } else { pd };
                                                state_remain = play_duration;
                                                bird_state = BirdState::Sounding;
                                            } else {
                                                state_remain -= 1;
                                            }
                                        }
                                        BirdState::Sounding => {
                                            let pos = play_duration - state_remain;
                                            let env = syllable_env(pos, play_duration);
                                            bird_mono = grain_read(grain, play_pos, syll_len) * env;
                                            play_pos += play_rate;
                                            state_remain -= 1;
                                            if state_remain == 0 {
                                                if repeats_left > 0 {
                                                    repeats_left -= 1;
                                                    bird_state = BirdState::Gap;
                                                    let gap = gap_min + rand_f(&mut rng) as f64 * (gap_max - gap_min);
                                                    state_remain = gap as u32;
                                                } else {
                                                    bird_state = BirdState::Waiting;
                                                    let pause = pause_min + rand_f(&mut rng) as f64 * (pause_max - pause_min);
                                                    state_remain = pause as u32;
                                                }
                                            }
                                        }
                                        BirdState::Gap => {
                                            if state_remain == 0 {
                                                // ── Start next syllable in the phrase ──
                                                bird_state = BirdState::Sounding;
                                                play_pos = 0.0;
                                                play_rate = base_rate * (1.0 + rand_bi(&mut rng) as f64 * pitch_var);
                                                let pd = (syll_len as f64 / play_rate) as u32;
                                                play_duration = if pd == 0 { 1 } else { pd };
                                                state_remain = play_duration;
                                            } else {
                                                state_remain -= 1;
                                            }
                                        }
                                    }

                                    // ── Per-channel mix ──
                                    for c in 0..n_ch {
                                        let dry = ctx.input(c, f);

                                        // Shape the bird's voice with a bandpass
                                        let bird_bp = bp[c].process_sample(bird_mono as f64) as f32;

                                        // Night-air reverb: parallel combs → allpass diffuser
                                        let mut rev = 0.0_f32;
                                        for i in 0..N_COMBS {
                                            let d = COMB_MS[c][i] * 0.001 * sr;
                                            let del = combs[c][i].read(d);
                                            combs[c][i].write(bird_bp + del * rev_fb);
                                            rev += del * 0.5;
                                        }
                                        let ap_d = AP_MS[c] * 0.001 * sr;
                                        let ap_del = ap[c].read(ap_d);
                                        let ap_g: f32 = 0.5;
                                        let ap_v = rev + ap_g * ap_del;
                                        ap[c].write(ap_v);
                                        let rev_out = -ap_g * ap_v + ap_del;

                                        // Faint insect-band noise bed
                                        let noise = rand_bi(&mut rng) * 0.15;
                                        let night = night_lp[c]
                                            .process_sample(night_hp[c].process_sample(noise as f64)) as f32;

                                        let wet_sig = bird_bp * 0.85 + rev_out * rev_amt + night * night_amt;
                                        let out = dry * (1.0 - wet) + wet_sig * wet;
                                        ctx.set_output(c, f, out);
                                    }
                                }
                            });
                        });
                    });
                });
            });
        });
    });

    BIRD_STATE.set(bird_state);
    STATE_REMAIN.set(state_remain);
    REPEATS_LEFT.set(repeats_left);
    SYLL_LEN.set(syll_len);
    PLAY_DURATION.set(play_duration);
    PLAY_POS.set(play_pos);
    PLAY_RATE.set(play_rate);
    BASE_RATE.set(base_rate);
    RNG.set(rng);
}
