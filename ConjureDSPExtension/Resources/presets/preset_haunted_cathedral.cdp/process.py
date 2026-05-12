
import numpy as np
from conjuredsp import (freq, time_ms, mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "decay": pct(default=85),
    "darkness": freq(min=200, max=16000, default=1800),
    "haunt": pct(default=60),
    "size": pct(default=80),
    "pre_delay": time_ms(1, 150, default=40),
    "mix": mix(default=0.5),
}

# Cathedral comb delay times (ms) — coprime-ish for dense reflection patterns
COMB_MS = [59.3, 67.7, 73.1, 79.9]
# Allpass diffuser times (ms)
AP_MS = [12.1, 4.3]
AP_G = 0.6

_st = None
_sr = None

class _S:
    def __init__(self, sr, nch):
        mx = int(0.5 * sr)
        self.pd = [DelayLine(mx) for _ in range(nch)]
        self.cb = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.clp = [[Biquad() for _ in range(4)] for _ in range(nch)]
        self.cfb = [[0.0] * 4 for _ in range(nch)]
        self.ap = [[DelayLine(mx) for _ in range(2)] for _ in range(nch)]
        self.aps = [[0.0] * 2 for _ in range(nch)]
        self.hp = [Biquad() for _ in range(nch)]
        self.lfos = [LFO(sr, freq=r, waveform="sine")
                     for r in [0.11, 0.15, 0.19, 0.27]]

def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    decay = ctx.params["decay"] / 100.0
    dark = ctx.params["darkness"]
    haunt = ctx.params["haunt"] / 100.0
    sz = 0.5 + ctx.params["size"] / 100.0
    pd_samp = ctx.params["pre_delay"] * 0.001 * ctx.sample_rate
    mx = ctx.params["mix"]

    fb = 0.75 + decay * 0.22
    lpc = BiquadCoeffs.lowpass(dark, 0.6, ctx.sample_rate)
    hpc = BiquadCoeffs.highpass(80.0, 0.707, ctx.sample_rate)
    mod_depth = haunt * 20.0

    # Set filter coefficients once per block
    for ch in range(nch):
        for c in range(4):
            s.clp[ch][c].set_coeffs(lpc)
        s.hp[ch].set_coeffs(hpc)

    # Precompute base delay times (stable within block)
    cb_d = [COMB_MS[c] * sz * 0.001 * ctx.sample_rate for c in range(4)]
    ap_d = [max(AP_MS[a] * sz * 0.001 * ctx.sample_rate, 1.0) for a in range(2)]

    for i in range(frame_count):
        m = [lfo.tick() for lfo in s.lfos]

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Pre-delay (cathedral distance)
            s.pd[ch].write(dry)
            x = s.pd[ch].read(pd_samp)

            # 4 parallel comb filters: dark feedback + ghostly pitch wobble
            csum = 0.0
            for c in range(4):
                d = max(cb_d[c] + m[c] * mod_depth, 1.0)
                flt = s.clp[ch][c].process_sample(s.cfb[ch][c])
                s.cb[ch][c].write(x + fb * flt)
                s.cfb[ch][c] = s.cb[ch][c].read_cubic(d)
                csum += s.cfb[ch][c]

            sig = csum * 0.25

            # 2 series allpass diffusers — thicken into wash
            for a in range(2):
                vd = s.aps[ch][a]
                vn = sig + AP_G * vd
                s.ap[ch][a].write(vn)
                s.aps[ch][a] = s.ap[ch][a].read(ap_d[a])
                sig = vd - AP_G * vn

            # Highpass wet signal to prevent rumble buildup
            sig = s.hp[ch].process_sample(sig)

            ctx.outputs[ch][i] = dry * (1.0 - mx) + sig * mx
