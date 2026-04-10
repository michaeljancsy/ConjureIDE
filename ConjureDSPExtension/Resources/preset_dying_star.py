# Dying Star — kick → dying star collapsing into a black hole.
#
# Sub-bass rumble bus (rectify → 80 Hz LP) → gravitational redshift dual-tap
# pitch shifter → 4 cascaded Schroeder allpass diffusers (dispersion lensing)
# → closing one-pole lowpass (collapse-controlled cutoff) → Schwarzschild
# resonance bandpass at 110 Hz → event-horizon bit reduction → final mix.
#
# Params:
#   collapse (pct) — closes lowpass cutoff + drives bit reduction
#   gravity  (pct) — pitch-shift drift rate
#   sub      (pct) — rumble bus level
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs)

PARAMS = {
    "collapse": pct(default=55),
    "gravity":  pct(default=60),
    "sub":      pct(default=70),
    "mix":      mix(default=0.6),
}

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


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    collapse = params["collapse"] / 100.0
    gravity = params["gravity"] / 100.0
    sub = params["sub"] / 100.0
    mx = params["mix"]

    # Sub-bass lowpass coefficients (80 Hz Q=0.7)
    sub_lpc = BiquadCoeffs.lowpass(80.0, 0.707, sample_rate)
    # Schwarzschild ringing bandpass at 110 Hz, Q=18
    ringc = BiquadCoeffs.bandpass(110.0, 18.0, sample_rate)
    for ch in range(nch):
        s.sub_lp[ch].set_coeffs(sub_lpc)
        s.ring[ch].set_coeffs(ringc)

    # Closing lowpass: cutoff sweeps from 8000 Hz (collapse=0) to 350 Hz (collapse=1)
    close_fc = 8000.0 - 7650.0 * collapse
    close_alpha = math.exp(-2.0 * math.pi * close_fc / sample_rate)
    close_one_minus = 1.0 - close_alpha

    # Pitch shifter
    base_d = SHIFT_BASE_MS * 0.001 * sample_rate
    grain_samples = GRAIN_MS * 0.001 * sample_rate
    # Grain phase advances at drift rate; full cycle = falls behind by grain_samples
    grain_rate = (0.4 + 1.6 * gravity) / grain_samples

    # Bit reduction: 8 bits at collapse=0, 2 bits at collapse=1
    bits = 8.0 - 6.0 * collapse
    levels = 2.0 ** bits
    inv_levels = 1.0 / levels

    # Allpass times in samples
    ap_d = [max(AP_MS[k] * 0.001 * sample_rate, 1.0) for k in range(4)]

    rumble_gain = sub * 1.5
    ring_gain = 0.4

    for i in range(frame_count):
        # Advance grain phase once per sample (shared across channels)
        ph0 = s.grain_phase
        ph1 = (s.grain_phase + 0.5) % 1.0
        # sin² window peaks at center of grain (0.5), zero at boundaries
        w0 = math.sin(math.pi * ph0)
        w0 = w0 * w0
        w1 = math.sin(math.pi * ph1)
        w1 = w1 * w1
        read0 = base_d + ph0 * grain_samples
        read1 = base_d + ph1 * grain_samples
        s.grain_phase = (s.grain_phase + grain_rate) % 1.0

        for ch in range(nch):
            dry = float(inputs[ch][i])

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
            s.close_lp[ch] = close_alpha * s.close_lp[ch] + close_one_minus * sig
            closed = s.close_lp[ch]

            # Stage E: Schwarzschild resonance bandpass (parallel)
            ringing = s.ring[ch].process_sample(closed) * ring_gain

            # Stage F: event-horizon bit reduction on the closed bus
            crushed = math.floor(closed * levels + 0.5) * inv_levels

            # Stage G: final wet sum + mix
            wet = rumble + crushed + ringing
            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
