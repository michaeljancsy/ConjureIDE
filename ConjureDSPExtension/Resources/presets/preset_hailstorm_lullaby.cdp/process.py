# Hailstorm Lullaby — ice on a tin roof over a sleeping child.
#
# Fast-attack envelope follower on |dry| → threshold-gated hail impact
# (deterministic LCG-based noise burst multiplied by the envelope → tin-roof
# clatter) → soft sub-pad bed (80 Hz LP of rectified input) → 2 allpass +
# 2-comb dark hall reverb whose wet amount is MODULATED by the envelope
# (envelope-gated reverb — the tail only opens on transients) → final mix.
#
# First envelope-gated reverb in the set. Juxtaposes stochastic percussive
# transients against a gentle sub pad.
#
# Params:
#   impact (pct) — hail noise level
#   patter (pct) — envelope threshold (lower → more hail)
#   subpad (pct) — sub-pad bed level
#   hall   (pct) — reverb feedback (dark hall tail)
#   mix          — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs)

PARAMS = {
    "impact": pct(default=65),
    "patter": pct(default=50),
    "subpad": pct(default=55),
    "hall":   pct(default=60),
    "mix":    mix(default=0.55),
}

AP_MS = [7.3, 11.1]
AP_G = 0.55
COMB_MS = [113.0, 167.0]

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.35 * sr)
        self.env = [0.0 for _ in range(nch)]
        self.sub_lp = [Biquad() for _ in range(nch)]
        self.ap = [[DelayLine(mx) for _ in range(2)] for _ in range(nch)]
        self.aps = [[0.0 for _ in range(2)] for _ in range(nch)]
        self.combs = [[DelayLine(mx) for _ in range(2)] for _ in range(nch)]
        self.comb_lp = [[Biquad() for _ in range(2)] for _ in range(nch)]
        self.comb_fb = [[0.0 for _ in range(2)] for _ in range(nch)]
        self.lcg_state = 0x13579BDF


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    impact = params["impact"] / 100.0
    patter = params["patter"] / 100.0
    subpad = params["subpad"] / 100.0
    hall = params["hall"] / 100.0
    mx = params["mix"]

    sub_lpc = BiquadCoeffs.lowpass(80.0, 0.707, sample_rate)
    comb_lpc = BiquadCoeffs.lowpass(1800.0, 0.707, sample_rate)
    for ch in range(nch):
        s.sub_lp[ch].set_coeffs(sub_lpc)
        for k in range(2):
            s.comb_lp[ch][k].set_coeffs(comb_lpc)

    # Envelope follower: fast attack (~2 ms), slow release (~80 ms)
    attack_alpha = 1.0 - math.exp(-1.0 / (0.002 * sample_rate))
    release_alpha = 1.0 - math.exp(-1.0 / (0.080 * sample_rate))

    ap_d = [max(AP_MS[k] * 0.001 * sample_rate, 1.0) for k in range(2)]
    comb_d = [COMB_MS[k] * 0.001 * sample_rate for k in range(2)]
    comb_fb_amt = 0.55 + 0.30 * hall

    thresh = 0.02 + 0.25 * (1.0 - patter)  # lower patter → higher thresh → less hail
    hail_gain = 2.0 + 4.0 * impact
    sub_gain = 0.6 + 1.4 * subpad

    for i in range(frame_count):
        # Deterministic LCG noise, shared across channels
        s.lcg_state = (s.lcg_state * 1103515245 + 12345) & 0x7FFFFFFF
        noise = (s.lcg_state / 2147483647.0) * 2.0 - 1.0

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Envelope follower (asymmetric attack/release)
            absx = abs(dry)
            if absx > s.env[ch]:
                s.env[ch] += (absx - s.env[ch]) * attack_alpha
            else:
                s.env[ch] += (absx - s.env[ch]) * release_alpha
            env = s.env[ch]

            # Hail trigger: only active above threshold
            if env > thresh:
                hail = noise * env * hail_gain
            else:
                hail = 0.0

            # Sub-pad bed
            sub_voice = s.sub_lp[ch].process_sample(absx) * sub_gain

            # Dark hall: allpass → combs
            sig = hail + sub_voice * 0.3
            for k in range(2):
                vd = s.aps[ch][k]
                vn = sig + AP_G * vd
                s.ap[ch][k].write(vn)
                s.aps[ch][k] = s.ap[ch][k].read(ap_d[k])
                sig = vd - AP_G * vn

            tail_sum = 0.0
            for k in range(2):
                f_in = s.comb_lp[ch][k].process_sample(s.comb_fb[ch][k])
                s.combs[ch][k].write(sig + comb_fb_amt * f_in)
                s.comb_fb[ch][k] = s.combs[ch][k].read(comb_d[k])
                tail_sum += s.comb_fb[ch][k]
            tail_sum = tail_sum * 0.5

            # Envelope-gated reverb: wet only opens on transients
            gate_amt = 0.25 + 0.75 * min(env * 3.0, 1.0)
            wet = hail + sub_voice + tail_sum * gate_amt

            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
