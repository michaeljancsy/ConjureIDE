# Termite Cathedral — vast stone hall full of insect chatter.
#
# 8-tap micro-grain cloud (short delay taps at 3–28 ms, each wavering via an
# independent coprime LFO) as the *primary* layer → 4-resonator chatter bank
# (high-Q bandpass at 800 / 1600 / 2700 / 4200 Hz) → 4 parallel cathedral
# combs (137 / 179 / 223 / 277 ms, LP in feedback) → final mix.
#
# Distinct from Glass Smash: here the granular cloud IS the sound, not a
# side stage. Distinct from Haunted Cathedral: narrower, chattier combs fed
# by a pre-diffused grain bed rather than raw input.
#
# Params:
#   density (pct) — cloud tap gain + LFO modulation depth
#   clatter (pct) — resonator Q (6 → 28)
#   hall    (pct) — comb reverb feedback
#   sheen   (pct) — post-reverb highpass freq (brightness)
#   mix           — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "density": pct(default=65),
    "clatter": pct(default=55),
    "hall":    pct(default=70),
    "sheen":   pct(default=50),
    "mix":     mix(default=0.6),
}

TAP_MS = [3.1, 5.3, 7.9, 11.7, 14.3, 18.1, 22.9, 27.7]
TAP_LFO_HZ = [0.7, 1.1, 1.4, 1.9, 2.3, 3.1, 4.1, 5.3]
RES_HZ = [800.0, 1600.0, 2700.0, 4200.0]
COMB_MS = [137.0, 179.0, 223.0, 277.0]

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.5 * sr)
        self.grain_dl = [DelayLine(mx) for _ in range(nch)]
        self.tap_lfo = [LFO(sr, freq=TAP_LFO_HZ[k], waveform="sine")
                        for k in range(8)]
        self.res = [[Biquad() for _ in range(4)] for _ in range(nch)]
        self.combs = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.comb_lp = [[Biquad() for _ in range(4)] for _ in range(nch)]
        self.comb_fb = [[0.0 for _ in range(4)] for _ in range(nch)]
        self.hp = [Biquad() for _ in range(nch)]


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    density = ctx.params["density"] / 100.0
    clatter = ctx.params["clatter"] / 100.0
    hall = ctx.params["hall"] / 100.0
    sheen = ctx.params["sheen"] / 100.0
    mx = ctx.params["mix"]

    res_q = 6.0 + 22.0 * clatter
    res_c = [BiquadCoeffs.bandpass(RES_HZ[k], res_q, ctx.sample_rate)
             for k in range(4)]
    comb_lpc = BiquadCoeffs.lowpass(3200.0, 0.707, ctx.sample_rate)
    hp_fc = 200.0 + 1800.0 * sheen
    hpc = BiquadCoeffs.highpass(hp_fc, 0.707, ctx.sample_rate)
    for ch in range(nch):
        for k in range(4):
            s.res[ch][k].set_coeffs(res_c[k])
            s.comb_lp[ch][k].set_coeffs(comb_lpc)
        s.hp[ch].set_coeffs(hpc)

    tap_base = [TAP_MS[k] * 0.001 * ctx.sample_rate for k in range(8)]
    tap_depth = (0.5 + 1.5 * density) * 0.001 * ctx.sample_rate
    comb_d = [COMB_MS[k] * 0.001 * ctx.sample_rate for k in range(4)]
    comb_fb_amt = 0.60 + 0.30 * hall

    tap_gain = (0.4 + 0.6 * density) / 8.0

    for i in range(frame_count):
        lm = [s.tap_lfo[k].tick() for k in range(8)]

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: write dry into shared grain delay
            s.grain_dl[ch].write(dry)

            # Stage B: 8-tap cloud with LFO-modulated positions
            cloud = 0.0
            for k in range(8):
                d = tap_base[k] + lm[k] * tap_depth
                if d < 1.0:
                    d = 1.0
                cloud += s.grain_dl[ch].read(d)
            cloud = cloud * tap_gain

            # Stage C: 4-resonator chatter bank
            res_sum = 0.0
            for k in range(4):
                res_sum += s.res[ch][k].process_sample(cloud)
            res_sum = res_sum * 0.25

            # Stage D: 4-comb cathedral tail
            comb_in = cloud + res_sum
            tail_sum = 0.0
            for k in range(4):
                f_in = s.comb_lp[ch][k].process_sample(s.comb_fb[ch][k])
                s.combs[ch][k].write(comb_in + comb_fb_amt * f_in)
                s.comb_fb[ch][k] = s.combs[ch][k].read(comb_d[k])
                tail_sum += s.comb_fb[ch][k]
            tail_sum = tail_sum * 0.25

            # Stage E: highpass for insect-chatter sheen
            wet = s.hp[ch].process_sample(cloud + res_sum + tail_sum)

            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
