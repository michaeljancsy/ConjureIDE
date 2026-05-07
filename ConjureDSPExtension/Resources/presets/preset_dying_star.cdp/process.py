# Dying Star — kick → dying star collapsing into a black hole.
#
# Sub-bass rumble bus (rectify → 80 Hz LP) → gravitational redshift dual-tap
# pitch shifter → 4 cascaded Schroeder allpass diffusers (dispersion lensing)
# → closing one-pole lowpass (collapse-controlled cutoff) → Schwarzschild
# resonance bandpass at 110 Hz → event-horizon bit reduction → final mix.
#
# Params:
#   collapse      (pct)    — closes lowpass cutoff + drives bit reduction
#   gravity       (pct)    — pitch-shift drift rate (Free mode only)
#   sub           (pct)    — rumble bus level
#   mix                    — wet/dry blend
#   gravity_sync  (choice) — lock pitch-shift grain phase to host beat
#   collapse_sync (choice) — beat-locked decay envelope on the closing lowpass

import math
from conjuredsp import (mix, pct, choice,
                        DelayLine, Biquad, BiquadCoeffs)

PARAMS = {
    "collapse":      pct(default=55),
    "gravity":       pct(default=60),
    "sub":           pct(default=70),
    "mix":           mix(default=0.6),
    "gravity_sync":  choice("Free", "1/16", "1/8", "1/4", "1/2", "1 bar", "2 bars"),
    "collapse_sync": choice("Free", "1/16", "1/8", "1/4", "1/2", "1 bar", "2 bars"),
}

# Sync division → quarter-note beats. None entries are computed per-call from
# the host's time signature numerator (1 bar = num quarter notes in N/4).
_SYNC_DIVISIONS = (None, 0.25, 0.5, 1.0, 2.0, None, None)

# Pitch shifter parameters
SHIFT_BASE_MS = 50.0       # base read offset behind write head
GRAIN_MS = 80.0            # grain length
# Dispersion allpass times (ms) — irrational ratios for max diffusion
AP_MS = [11.3, 17.7, 23.1, 29.9]
AP_G = 0.65

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.5 * sr)
        self.sub_lp = [Biquad() for _ in range(nch)]
        self.shift_dl = [DelayLine(mx) for _ in range(nch)]
        self.ap = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.aps = [[0.0 for _ in range(4)] for _ in range(nch)]
        self.close_lp = [0.0 for _ in range(nch)]
        self.ring = [Biquad() for _ in range(nch)]
        self.grain_phase = 0.0


def _resolve_sync(idx, time_sig_num):
    """Map a sync choice index → division length in quarter notes, or 0 for Free."""
    if idx <= 0 or idx >= len(_SYNC_DIVISIONS):
        return 0.0
    div = _SYNC_DIVISIONS[idx]
    if div is not None:
        return div
    # 1 bar = time_sig_num quarter notes; 2 bars = 2 * time_sig_num
    bar = float(time_sig_num) if time_sig_num > 0 else 4.0
    return bar if idx == 5 else 2.0 * bar


def process(ctx):
    global _st, _sr
    nch = len(ctx.inputs)
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    collapse = ctx.params["collapse"] / 100.0
    gravity = ctx.params["gravity"] / 100.0
    sub = ctx.params["sub"] / 100.0
    mx = ctx.params["mix"]

    # Host transport for beat-locked sync. If the host isn't playing or has no
    # tempo, both sync modes fall back to free-running so the preset still
    # works in auval and stopped DAWs.
    tempo = ctx.transport.bpm
    beat = ctx.transport.beat
    playing = ctx.transport.is_playing
    time_sig_num = ctx.transport.time_sig_numerator
    sync_active = bool(playing) and tempo > 0.0
    beats_per_sample = (tempo / 60.0) / ctx.sample_rate if sync_active else 0.0

    grav_div = _resolve_sync(int(round(ctx.params["gravity_sync"])), time_sig_num) if sync_active else 0.0
    coll_div = _resolve_sync(int(round(ctx.params["collapse_sync"])), time_sig_num) if sync_active else 0.0
    grav_synced = grav_div > 0.0
    coll_synced = coll_div > 0.0

    # Sub-bass lowpass coefficients (80 Hz Q=0.7)
    sub_lpc = BiquadCoeffs.lowpass(80.0, 0.707, ctx.sample_rate)
    # Schwarzschild ringing bandpass at 110 Hz, Q=18
    ringc = BiquadCoeffs.bandpass(110.0, 18.0, ctx.sample_rate)
    for ch in range(nch):
        s.sub_lp[ch].set_coeffs(sub_lpc)
        s.ring[ch].set_coeffs(ringc)

    # Closing lowpass: cutoff sweeps from 8000 Hz (collapse=0) to 350 Hz (collapse=1)
    close_fc = 8000.0 - 7650.0 * collapse
    close_alpha = math.exp(-2.0 * math.pi * close_fc / ctx.sample_rate)
    close_one_minus = 1.0 - close_alpha

    # Pitch shifter
    base_d = SHIFT_BASE_MS * 0.001 * ctx.sample_rate
    grain_samples = GRAIN_MS * 0.001 * ctx.sample_rate
    # Grain phase advances at drift rate; full cycle = falls behind by grain_samples
    grain_rate = (0.4 + 1.6 * gravity) / grain_samples

    # Bit reduction: 8 bits at collapse=0, 2 bits at collapse=1
    bits = 8.0 - 6.0 * collapse
    levels = 2.0 ** bits
    inv_levels = 1.0 / levels

    # Allpass times in samples
    ap_d = [max(AP_MS[k] * 0.001 * ctx.sample_rate, 1.0) for k in range(4)]

    rumble_gain = sub * 1.5
    ring_gain = 0.4

    for i in range(ctx.frame_count):
        # Pitch-shifter grain phase: free-running by default, beat-locked when synced.
        if grav_synced:
            beat_now = beat + i * beats_per_sample
            ph0 = (beat_now / grav_div) % 1.0
        else:
            ph0 = s.grain_phase
            s.grain_phase = (s.grain_phase + grain_rate) % 1.0
        ph1 = (ph0 + 0.5) % 1.0
        # sin² window peaks at center of grain (0.5), zero at boundaries
        w0 = math.sin(math.pi * ph0)
        w0 = w0 * w0
        w1 = math.sin(math.pi * ph1)
        w1 = w1 * w1
        read0 = base_d + ph0 * grain_samples
        read1 = base_d + ph1 * grain_samples

        # Closing-lowpass coefficients: per-buffer in Free mode, per-sample when
        # collapse is beat-pulsed. Bit reduction stays tied to the static collapse.
        if coll_synced:
            beat_now = beat + i * beats_per_sample
            pulse_phase = (beat_now / coll_div) % 1.0
            pulse_env = math.exp(-3.0 * pulse_phase)
            eff_collapse = collapse + (1.0 - collapse) * pulse_env
            if eff_collapse > 1.0:
                eff_collapse = 1.0
            cur_close_fc = 8000.0 - 7650.0 * eff_collapse
            cur_close_alpha = math.exp(-2.0 * math.pi * cur_close_fc / ctx.sample_rate)
            cur_close_one_minus = 1.0 - cur_close_alpha
        else:
            cur_close_alpha = close_alpha
            cur_close_one_minus = close_one_minus

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: sub-bass rumble bus (rectify → LP → gain)
            rectified = abs(dry)
            rumble = s.sub_lp[ch].process_sample(rectified) * rumble_gain

            # Stage B: gravitational redshift pitch shift (dual-tap crossfade)
            s.shift_dl[ch].write(dry)
            g0 = s.shift_dl[ch].read(read0)
            g1 = s.shift_dl[ch].read(read1)
            shifted = w0 * g0 + w1 * g1

            # Stage C: 4 cascaded Schroeder allpass diffusers (lensing)
            sig = shifted
            for k in range(4):
                vd = s.aps[ch][k]
                vn = sig + AP_G * vd
                s.ap[ch][k].write(vn)
                s.aps[ch][k] = s.ap[ch][k].read(ap_d[k])
                sig = vd - AP_G * vn

            # Stage D: closing one-pole lowpass
            s.close_lp[ch] = cur_close_alpha * s.close_lp[ch] + cur_close_one_minus * sig
            closed = s.close_lp[ch]

            # Stage E: Schwarzschild resonance bandpass (parallel)
            ringing = s.ring[ch].process_sample(closed) * ring_gain

            # Stage F: event-horizon bit reduction on the closed bus
            crushed = math.floor(closed * levels + 0.5) * inv_levels

            # Stage G: final wet sum + mix
            wet = rumble + crushed + ringing
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
