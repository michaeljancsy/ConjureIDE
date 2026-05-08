# Last Transmission — a dying SOS broadcast through static.
#
# Narrow telegraph bandpass (800 Hz center, high Q) → dropout envelope
# (3 slow LFOs at 0.19 / 0.43 / 0.8 Hz summed; when sum falls below a
# dropout-scaled threshold the signal goes silent) → soft tanh fuzz
# scaled by the dropout envelope → small far reverb (2 allpass + short
# comb) → final mix.
#
# Distinct from Alien Radio: intimate, decaying single-channel transmission
# rather than wide stereo broadcast. First preset where dropout density is
# the primary expressive control.
#
# Params:
#   radio    (pct) — bandpass narrowness (Q)
#   dropout  (pct) — dropout density
#   fuzz     (pct) — tanh saturation drive
#   distance (pct) — far-reverb amount
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "radio":    pct(default=70),
    "dropout":  pct(default=55),
    "fuzz":     pct(default=50),
    "distance": pct(default=40),
    "mix":      mix(default=0.6),
}

BP_HZ = 800.0
DROPOUT_HZ = [0.19, 0.43, 0.8]
AP_MS = [5.3, 7.9]
AP_G = 0.5
COMB_MS = 67.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.15 * sr)
        self.bp = [Biquad() for _ in range(nch)]
        self.dropout_lfo = [LFO(sr, freq=DROPOUT_HZ[k], waveform="sine")
                            for k in range(3)]
        self.ap = [[DelayLine(mx) for _ in range(2)] for _ in range(nch)]
        self.aps = [[0.0 for _ in range(2)] for _ in range(nch)]
        self.comb = [DelayLine(mx) for _ in range(nch)]
        self.comb_fb = [0.0 for _ in range(nch)]
        self.comb_lp = [Biquad() for _ in range(nch)]


def process(ctx):
    global _st, _sr
    nch = len(ctx.inputs)
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    radio = ctx.params["radio"] / 100.0
    dropout = ctx.params["dropout"] / 100.0
    fuzz = ctx.params["fuzz"] / 100.0
    distance = ctx.params["distance"] / 100.0
    mx = ctx.params["mix"]

    bp_q = 4.0 + 12.0 * radio
    bp_c = BiquadCoeffs.bandpass(BP_HZ, bp_q, ctx.sample_rate)
    comb_lpc = BiquadCoeffs.lowpass(1600.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        s.bp[ch].set_coeffs(bp_c)
        s.comb_lp[ch].set_coeffs(comb_lpc)

    ap_d = [max(AP_MS[k] * 0.001 * ctx.sample_rate, 1.0) for k in range(2)]
    comb_d = COMB_MS * 0.001 * ctx.sample_rate
    comb_fb_amt = 0.45 + 0.40 * distance

    drive = 1.0 + 5.0 * fuzz
    # Dropout threshold: higher dropout → higher threshold → more silence
    drop_thresh = -0.4 + 1.2 * dropout

    for i in range(ctx.frame_count):
        d0 = s.dropout_lfo[0].tick()
        d1 = s.dropout_lfo[1].tick()
        d2 = s.dropout_lfo[2].tick()
        drop_env = (d0 + d1 + d2) / 3.0
        # Smooth gate: above threshold → 1, below → 0
        gate = drop_env - drop_thresh
        if gate < 0.0:
            gate_val = 0.0
        elif gate > 0.3:
            gate_val = 1.0
        else:
            # Linear ramp in [0, 0.3]
            gate_val = gate / 0.3

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: narrow telegraph bandpass
            filtered = s.bp[ch].process_sample(dry)

            # Stage B: dropout gate
            gated = filtered * gate_val

            # Stage C: fuzz scaled by gate
            fuzzed = math.tanh(gated * drive) / drive

            # Stage D: 2 allpass diffusers
            sig = fuzzed
            for k in range(2):
                vd = s.aps[ch][k]
                vn = sig + AP_G * vd
                s.ap[ch][k].write(vn)
                s.aps[ch][k] = s.ap[ch][k].read(ap_d[k])
                sig = vd - AP_G * vn

            # Stage E: short far reverb comb
            f_in = s.comb_lp[ch].process_sample(s.comb_fb[ch])
            s.comb[ch].write(sig + comb_fb_amt * f_in)
            s.comb_fb[ch] = s.comb[ch].read(comb_d)

            wet = fuzzed + sig * 0.4 + s.comb_fb[ch] * 0.5
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
