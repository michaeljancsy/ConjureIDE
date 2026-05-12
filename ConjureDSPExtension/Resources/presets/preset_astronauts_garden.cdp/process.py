# Astronaut's Garden — bell-like organic blooms drifting in a vacuum.
#
# Just-intonation harmonic resonator bank (8 partials at 1, 2, 3, 5, 6, 7, 9,
# 11 × 220 Hz fundamental, high-Q bandpass) → sub-Hz ring modulation (very
# slow LFO carriers, 0.13 / 0.21 Hz) → 4-voice prime-spaced chorus → spacious
# lowpass-feedback comb reverb → final mix.
#
# Distinct from Glass Smash: this bank is *harmonic* (just-intonation) rather
# than inharmonic glass spectra, producing bell-like consonant blooms instead
# of metallic crash. Sub-Hz ring-mod carriers swell rather than buzz.
#
# Params:
#   bloom    (pct) — resonator Q (10 → 30)
#   drift    (pct) — sub-Hz ring-mod depth
#   chorus   (pct) — chorus depth
#   garden   (pct) — reverb feedback
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        DelayLine, Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "bloom":  pct(default=55),
    "drift":  pct(default=60),
    "chorus": pct(default=50),
    "garden": pct(default=65),
    "mix":    mix(default=0.55),
}

# Just-intonation harmonic ratios above 220 Hz fundamental
FUNDAMENTAL = 220.0
HARMONICS = [1.0, 2.0, 3.0, 5.0, 6.0, 7.0, 9.0, 11.0]
# Sub-Hz ring-mod LFO rates (Hz) — coprime drift
RING_HZ = [0.13, 0.21]
# Chorus voice base delays (ms) — prime-spaced
CHORUS_MS = [7.0, 11.0, 13.0, 19.0]
# Chorus LFO rates (Hz) — coprime
CHORUS_LFO_HZ = [0.31, 0.43, 0.57, 0.71]
# Reverb comb times (ms)
COMB_MS = [83.0, 109.0, 137.0, 167.0]

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        mx = int(0.4 * sr)
        self.modal = [[Biquad() for _ in range(8)] for _ in range(nch)]
        self.ring_lfo = [LFO(sr, freq=RING_HZ[k], waveform="sine") for k in range(2)]
        self.chorus_dl = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.chorus_lfo = [LFO(sr, freq=CHORUS_LFO_HZ[k], waveform="sine") for k in range(4)]
        self.combs = [[DelayLine(mx) for _ in range(4)] for _ in range(nch)]
        self.comb_lp = [[Biquad() for _ in range(4)] for _ in range(nch)]
        self.comb_fb = [[0.0 for _ in range(4)] for _ in range(nch)]


def process(ctx):
    global _st, _sr
    nch, frame_count = ctx.inputs.shape
    if _st is None or _sr != ctx.sample_rate:
        _st = _S(ctx.sample_rate, nch)
        _sr = ctx.sample_rate

    s = _st
    bloom = ctx.params["bloom"] / 100.0
    drift = ctx.params["drift"] / 100.0
    chorus = ctx.params["chorus"] / 100.0
    garden = ctx.params["garden"] / 100.0
    mx = ctx.params["mix"]

    modal_q = 10.0 + 20.0 * bloom
    modal_c = []
    for k in range(8):
        f = FUNDAMENTAL * HARMONICS[k]
        if f > ctx.sample_rate * 0.45:
            f = ctx.sample_rate * 0.45
        modal_c.append(BiquadCoeffs.bandpass(f, modal_q, ctx.sample_rate))
    comb_lpc = BiquadCoeffs.lowpass(3500.0, 0.707, ctx.sample_rate)
    for ch in range(nch):
        for k in range(8):
            s.modal[ch][k].set_coeffs(modal_c[k])
        for k in range(4):
            s.comb_lp[ch][k].set_coeffs(comb_lpc)

    chorus_base = [CHORUS_MS[k] * 0.001 * ctx.sample_rate for k in range(4)]
    chorus_depth = (1.5 + 4.5 * chorus) * 0.001 * ctx.sample_rate
    comb_d = [COMB_MS[k] * 0.001 * ctx.sample_rate for k in range(4)]
    comb_fb_amt = 0.55 + 0.30 * garden

    modal_gain = 1.0 / 8.0
    ring_depth = 0.5 + 0.5 * drift  # depth of carrier amplitude

    for i in range(frame_count):
        # Sub-Hz LFOs (ring carriers — both shared across channels)
        r0 = s.ring_lfo[0].tick()
        r1 = s.ring_lfo[1].tick()
        # Chorus modulators
        c0 = s.chorus_lfo[0].tick()
        c1 = s.chorus_lfo[1].tick()
        c2 = s.chorus_lfo[2].tick()
        c3 = s.chorus_lfo[3].tick()
        cd = [c0, c1, c2, c3]

        # Combined ring carrier with sub-Hz amplitude swell
        carrier = (1.0 - ring_depth) + ring_depth * 0.5 * (r0 + r1)

        for ch in range(nch):
            dry = float(ctx.inputs[ch][i])

            # Stage A: 8-partial just-intonation modal bank
            modal_sum = 0.0
            for k in range(8):
                modal_sum += s.modal[ch][k].process_sample(dry)
            modal_sum = modal_sum * modal_gain

            # Stage B: ring modulation with sub-Hz carrier
            rung = modal_sum * carrier

            # Stage C: 4-voice chorus
            chorus_sum = 0.0
            for k in range(4):
                d = chorus_base[k] + cd[k] * chorus_depth
                if d < 1.0:
                    d = 1.0
                s.chorus_dl[ch][k].write(rung)
                chorus_sum += s.chorus_dl[ch][k].read(d)
            chorus_sum = chorus_sum * 0.25

            # Stage D: 4-comb spacious reverb
            tail_sum = 0.0
            for k in range(4):
                f_in = s.comb_lp[ch][k].process_sample(s.comb_fb[ch][k])
                s.combs[ch][k].write(chorus_sum + comb_fb_amt * f_in)
                s.comb_fb[ch][k] = s.combs[ch][k].read(comb_d[k])
                tail_sum += s.comb_fb[ch][k]
            tail_sum = tail_sum * 0.25

            wet = chorus_sum + tail_sum
            ctx.outputs[ch][i] = dry * (1.0 - mx) + wet * mx
