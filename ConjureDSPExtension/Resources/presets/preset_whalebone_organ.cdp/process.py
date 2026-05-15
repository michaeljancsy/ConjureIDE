# Whalebone Organ — a pipe organ carved from cetacean bone, sub harmonics
# resonating through the hull.
#
# Sub-octave generator (rectify → 70 Hz LP) → low/mid 8-partial modal bank
# (82.4 / 123.5 / 164.8 / 220 / 329.6 / 440 / 523.3 / 659.3 Hz high-Q
# bandpass — E-major chord voicings in the 80–660 Hz range) with slow
# per-partial amplitude LFOs ("breathing" 0.11–0.37 Hz) → 2 allpass
# diffusers → short comb tail → final mix.
#
# Distinct from Glass Smash: low-range modal bank (80–660 Hz) vs Glass
# Smash's high inharmonic bank (2.7–11.2 kHz). Distinct from Astronaut's
# Garden: pipe-organ sustain via per-partial breathing envelopes instead of
# shared sub-Hz ring modulation.
#
# Controls:
#   pipes  (pct) — modal resonator Q (12 → 40)
#   breath (pct) — per-partial breathing LFO depth
#   sub    (pct) — sub-octave level
#   air    (pct) — reverb feedback
#   mix          — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "pipes":  pct(default=60),
    "breath": pct(default=55),
    "sub":    pct(default=55),
    "air":    pct(default=50),
    "mix":    mix(default=0.55),
}

PIPE_HZ = [82.4, 123.5, 164.8, 220.0, 329.6, 440.0, 523.3, 659.3]
BREATH_HZ = [0.11, 0.13, 0.17, 0.19, 0.23, 0.29, 0.31, 0.37]
AP_MS = [9.7, 13.1]
AP_G = 0.55
COMB_MS = [97.0, 131.0]

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.3 * sr)
        self.sub_lp = [Biquad() for _ in range(nch)]
        self.pipes = [[Biquad() for _ in range(8)] for _ in range(nch)]
        self.breath_lfo = [LFO(sr, freq=BREATH_HZ[k], waveform="sine")
                           for k in range(8)]
        self.ap = [[DelayLine(mx) for _ in range(2)] for _ in range(nch)]
        self.aps = [[0.0 for _ in range(2)] for _ in range(nch)]
        self.combs = [[DelayLine(mx) for _ in range(2)] for _ in range(nch)]
        self.comb_lp = [[Biquad() for _ in range(2)] for _ in range(nch)]
        self.comb_fb = [[0.0 for _ in range(2)] for _ in range(nch)]


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    pipes = ctx.params["pipes"] / 100.0
    breath = ctx.params["breath"] / 100.0
    sub = ctx.params["sub"] / 100.0
    air = ctx.params["air"] / 100.0
    mx = ctx.params["mix"]

    pipe_q = 12.0 + 28.0 * pipes
    pipe_c = [BiquadCoeffs.bandpass(PIPE_HZ[k], pipe_q, ctx.sample_rate)
              for k in range(8)]
    sub_lpc = BiquadCoeffs.lowpass(70.0, 0.707, ctx.sample_rate)
    comb_lpc = BiquadCoeffs.lowpass(2200.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        s.sub_lp[ch].set_coeffs(sub_lpc)
        for k in range(8):
            s.pipes[ch][k].set_coeffs(pipe_c[k])
        for k in range(2):
            s.comb_lp[ch][k].set_coeffs(comb_lpc)

    ap_d = [max(AP_MS[k] * 0.001 * ctx.sample_rate, 1.0) for k in range(2)]
    comb_d = [COMB_MS[k] * 0.001 * ctx.sample_rate for k in range(2)]
    comb_fb_amt = 0.50 + 0.35 * air

    sub_gain = 0.4 + 0.8 * sub
    pipe_base_gain = 1.0 / 8.0
    breath_depth = 0.50 * breath

    for i in range(frame_count):
        bm = [s.breath_lfo[k].tick() for k in range(8)]

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: sub-octave from rectified envelope
            sub_voice = s.sub_lp[ch].process_sample(abs(dry)) * sub_gain

            # Stage B: 8-partial pipe bank with per-partial breathing
            pipe_sum = 0.0
            for k in range(8):
                voice = s.pipes[ch][k].process_sample(dry)
                gain = (1.0 - breath_depth) + breath_depth * (0.5 + 0.5 * bm[k])
                pipe_sum += voice * gain
            pipe_sum = pipe_sum * pipe_base_gain

            # Stage C: 2 allpass diffusers (bone reverb)
            sig = pipe_sum + sub_voice
            for k in range(2):
                vd = s.aps[ch][k]
                vn = sig + AP_G * vd
                s.ap[ch][k].write(vn)
                s.aps[ch][k] = s.ap[ch][k].read(ap_d[k])
                sig = vd - AP_G * vn

            # Stage D: 2 parallel comb tails
            tail_sum = 0.0
            for k in range(2):
                f_in = s.comb_lp[ch][k].process_sample(s.comb_fb[ch][k])
                s.combs[ch][k].write(sig + comb_fb_amt * f_in)
                s.comb_fb[ch][k] = s.combs[ch][k].read(comb_d[k])
                tail_sum += s.comb_fb[ch][k]
            tail_sum = tail_sum * 0.5

            wet = pipe_sum + sub_voice + sig * 0.3 + tail_sum
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
