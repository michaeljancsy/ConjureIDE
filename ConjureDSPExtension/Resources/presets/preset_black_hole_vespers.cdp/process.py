# Black Hole Vespers — gravitational drone with a slow choral chant stretched
# by time dilation.
#
# Sub-bass drone bus (rectify → 60 Hz LP) → very slow downward pitch sweep
# (dual-tap shifter) → 6 cascaded Schroeder allpass diffusers (longest reverb
# in the showcase) → swelling vowel formant cluster (3 peaking EQs at 500,
# 1100, 2200 Hz) → dark feedback comb tail → final mix.
#
# No distortion — this is the religious/contemplative cousin of Dying Star's
# catastrophic collapse.
#
# Params:
#   dilation (pct) — pitch sweep depth/rate
#   chant    (pct) — vowel formant gain
#   drone    (pct) — sub bus level
#   space    (pct) — comb reverb feedback (longest tail)
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs)

PARAMS = {
    "dilation": pct(default=55),
    "chant":    pct(default=60),
    "drone":    pct(default=70),
    "space":    pct(default=75),
    "mix":      mix(default=0.6),
}

# Pitch shifter
SHIFT_BASE_MS = 80.0
GRAIN_MS = 140.0
# Cathedral allpass times (ms) — 6 stages for maximum diffusion
AP_MS = [7.3, 11.9, 17.3, 23.1, 31.7, 41.3]
AP_G = 0.62
# Vowel formant frequencies (Hz) — chant-like "oo→ah" cluster
FORMANT_HZ = [500.0, 1100.0, 2200.0]
# Long tail comb time (ms)
TAIL_MS = 530.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.7 * sr)
        self.drone_lp = [Biquad() for _ in range(nch)]
        self.shift_dl = [DelayLine(mx) for _ in range(nch)]
        self.ap = [[DelayLine(mx) for _ in range(6)] for _ in range(nch)]
        self.aps = [[0.0 for _ in range(6)] for _ in range(nch)]
        self.formant = [[Biquad() for _ in range(3)] for _ in range(nch)]
        self.tail_dl = [DelayLine(mx) for _ in range(nch)]
        self.tail_lp = [Biquad() for _ in range(nch)]
        self.tail_fb = [0.0 for _ in range(nch)]
        self.grain_phase = 0.0


def process(ctx):
    global _st, _sr
    nch = len(ctx.inputs)
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    dilation = ctx.params["dilation"] / 100.0
    chant = ctx.params["chant"] / 100.0
    drone = ctx.params["drone"] / 100.0
    space = ctx.params["space"] / 100.0
    mx = ctx.params["mix"]

    drone_lpc = BiquadCoeffs.lowpass(60.0, 0.707, ctx.sample_rate)
    formant_c = [BiquadCoeffs.peak(FORMANT_HZ[k], 5.0, 8.0, ctx.sample_rate)
                 for k in range(3)]
    tail_lpc = BiquadCoeffs.lowpass(2200.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        s.drone_lp[ch].set_coeffs(drone_lpc)
        for k in range(3):
            s.formant[ch][k].set_coeffs(formant_c[k])
        s.tail_lp[ch].set_coeffs(tail_lpc)

    base_d = SHIFT_BASE_MS * 0.001 * ctx.sample_rate
    grain_samples = GRAIN_MS * 0.001 * ctx.sample_rate
    # Slower than Burial at Sea — time dilation
    grain_rate = (0.15 + 0.55 * dilation) / grain_samples

    ap_d = [max(AP_MS[k] * 0.001 * ctx.sample_rate, 1.0) for k in range(6)]
    tail_d = TAIL_MS * 0.001 * ctx.sample_rate
    tail_fb_amt = 0.60 + 0.25 * space

    drone_gain = drone * 1.4
    chant_gain = 0.18 + 0.32 * chant

    for i in range(ctx.frame_count):
        ph0 = s.grain_phase
        ph1 = (s.grain_phase + 0.5) % 1.0
        w0 = math.sin(math.pi * ph0)
        w0 = w0 * w0
        w1 = math.sin(math.pi * ph1)
        w1 = w1 * w1
        read0 = base_d + ph0 * grain_samples
        read1 = base_d + ph1 * grain_samples
        s.grain_phase = (s.grain_phase + grain_rate) % 1.0

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: sub drone bus
            drone_voice = s.drone_lp[ch].process_sample(abs(dry)) * drone_gain

            # Stage B: dilated downward pitch sweep
            s.shift_dl[ch].write(dry)
            g0 = s.shift_dl[ch].read(read0)
            g1 = s.shift_dl[ch].read(read1)
            shifted = w0 * g0 + w1 * g1

            # Stage C: 6 cascaded Schroeder allpass diffusers (cathedral wash)
            sig = shifted
            for k in range(6):
                vd = s.aps[ch][k]
                vn = sig + AP_G * vd
                s.ap[ch][k].write(vn)
                s.aps[ch][k] = s.ap[ch][k].read(ap_d[k])
                sig = vd - AP_G * vn

            # Stage D: vowel formant cluster (3 series peaking EQs)
            voiced = sig
            voiced = s.formant[ch][0].process_sample(voiced)
            voiced = s.formant[ch][1].process_sample(voiced)
            voiced = s.formant[ch][2].process_sample(voiced)
            voiced = voiced * chant_gain

            # Stage E: long feedback comb tail
            f_in = s.tail_lp[ch].process_sample(s.tail_fb[ch])
            s.tail_dl[ch].write(voiced + tail_fb_amt * f_in)
            s.tail_fb[ch] = s.tail_dl[ch].read(tail_d)

            wet = drone_voice + voiced + s.tail_fb[ch] * 0.6
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
