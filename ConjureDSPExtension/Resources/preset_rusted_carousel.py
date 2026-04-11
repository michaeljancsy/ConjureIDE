# Rusted Carousel — a derelict fairground organ playing a lopsided waltz.
#
# 5-voice calliope chorus (prime-spaced 9 / 13 / 17 / 23 / 29 ms base
# delays, each modulated by its own 0.17–0.41 Hz LFO — ±25¢-ish detune) →
# waltz amplitude LFO (1.2 Hz triangle shaped as |tri| to pulse in 3s) →
# pipe-pitch feedback comb at 110 Hz (~9.09 ms) → asymmetric tube-style
# tanh saturation → final mix.
#
# Distinct from Broken Fax Lullaby: metered waltz LFO rather than coprime
# square gating; detuned-organ texture. Distinct from Underwater Spy: the
# chorus itself is the rust/character, not a lush doubling effect.
#
# Params:
#   calliope (pct) — chorus depth
#   waltz    (pct) — waltz amplitude modulation depth
#   organ    (pct) — pipe comb feedback
#   tube     (pct) — asymmetric tanh drive
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "calliope": pct(default=60),
    "waltz":    pct(default=55),
    "organ":    pct(default=50),
    "tube":     pct(default=45),
    "mix":      mix(default=0.55),
}

CHORUS_MS = [9.0, 13.0, 17.0, 23.0, 29.0]
CHORUS_LFO_HZ = [0.17, 0.23, 0.29, 0.37, 0.41]
WALTZ_HZ = 1.2
PIPE_HZ = 110.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.1 * sr)
        self.chorus_dl = [[DelayLine(mx) for _ in range(5)] for _ in range(nch)]
        self.chorus_lfo = [LFO(sr, freq=CHORUS_LFO_HZ[k], waveform="sine")
                           for k in range(5)]
        self.waltz_lfo = LFO(sr, freq=WALTZ_HZ, waveform="triangle")
        self.pipe_dl = [DelayLine(mx) for _ in range(nch)]
        self.pipe_fb = [0.0 for _ in range(nch)]
        self.pipe_lp = [Biquad() for _ in range(nch)]


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    calliope = params["calliope"] / 100.0
    waltz = params["waltz"] / 100.0
    organ = params["organ"] / 100.0
    tube = params["tube"] / 100.0
    mx = params["mix"]

    pipe_lpc = BiquadCoeffs.lowpass(2800.0, 0.707, sample_rate)
    for ch in range(nch):
        s.pipe_lp[ch].set_coeffs(pipe_lpc)

    chorus_base = [CHORUS_MS[k] * 0.001 * sample_rate for k in range(5)]
    chorus_depth = (0.8 + 1.8 * calliope) * 0.001 * sample_rate
    waltz_depth = 0.65 * waltz
    pipe_d = (1.0 / PIPE_HZ) * sample_rate
    pipe_fb_amt = 0.50 + 0.40 * organ

    drive_pos = 1.0 + 3.0 * tube
    drive_neg = 1.0 + 1.5 * tube  # asymmetric

    chorus_gain = 1.0 / 5.0

    for i in range(frame_count):
        cm = [s.chorus_lfo[k].tick() for k in range(5)]
        w_tri = s.waltz_lfo.tick()
        waltz_mod = (1.0 - waltz_depth) + waltz_depth * abs(w_tri)

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: 5-voice calliope chorus
            chorus_sum = 0.0
            for k in range(5):
                d = chorus_base[k] + cm[k] * chorus_depth
                if d < 1.0:
                    d = 1.0
                s.chorus_dl[ch][k].write(dry)
                chorus_sum += s.chorus_dl[ch][k].read(d)
            chorus_sum = chorus_sum * chorus_gain

            # Stage B: waltz amplitude pulse
            pulsed = chorus_sum * waltz_mod

            # Stage C: pipe-pitch feedback comb
            f_in = s.pipe_lp[ch].process_sample(s.pipe_fb[ch])
            s.pipe_dl[ch].write(pulsed + pipe_fb_amt * f_in)
            s.pipe_fb[ch] = s.pipe_dl[ch].read(pipe_d)

            # Stage D: asymmetric tube saturation
            x = pulsed + s.pipe_fb[ch] * 0.6
            if x >= 0.0:
                wet = math.tanh(x * drive_pos) / drive_pos
            else:
                wet = math.tanh(x * drive_neg) / drive_neg

            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
