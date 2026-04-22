# Plague Doctor — medieval mask, breath rasping behind formant chambers.
#
# 3 cascaded nasal/throat peak EQs (250 / 700 / 2200 Hz, Q=4, +9 dB) → slow
# 0.3 Hz triangle "breath" envelope (asymmetric, modulates amplitude ±60%)
# → midrange presence peak EQ (1200 Hz, Q=2, +6 dB) → soft tanh saturation
# → close dry space (no reverb) → final mix.
#
# Distinct from Ghost Choir: dry/close formant treatment with nasal/throat
# vowel cluster vs Ghost Choir's wet/wide "ah" formants. Breath envelope is
# an expressive control rather than decorative modulation.
#
# Params:
#   mask     (pct) — nasal formant cluster gain
#   breath   (pct) — breath envelope depth
#   rasp     (pct) — tanh saturation drive
#   presence (pct) — midrange presence peak gain
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "mask":     pct(default=65),
    "breath":   pct(default=55),
    "rasp":     pct(default=50),
    "presence": pct(default=55),
    "mix":      mix(default=0.6),
}

FORMANT_HZ = [250.0, 700.0, 2200.0]
BREATH_HZ = 0.3
PRESENCE_HZ = 1200.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        self.formant = [[Biquad() for _ in range(3)] for _ in range(nch)]
        self.presence = [Biquad() for _ in range(nch)]
        self.breath_lfo = LFO(sr, freq=BREATH_HZ, waveform="triangle")


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    mask = params["mask"] / 100.0
    breath = params["breath"] / 100.0
    rasp = params["rasp"] / 100.0
    presence = params["presence"] / 100.0
    mx = params["mix"]

    formant_gain = 4.0 + 8.0 * mask
    formant_c = [BiquadCoeffs.peak(FORMANT_HZ[k], 4.0, formant_gain, sample_rate)
                 for k in range(3)]
    presence_gain = 2.0 + 6.0 * presence
    presence_c = BiquadCoeffs.peak(PRESENCE_HZ, 2.0, presence_gain, sample_rate)
    for ch in range(nch):
        for k in range(3):
            s.formant[ch][k].set_coeffs(formant_c[k])
        s.presence[ch].set_coeffs(presence_c)

    breath_depth = 0.60 * breath
    drive = 1.0 + 3.5 * rasp

    for i in range(frame_count):
        tri = s.breath_lfo.tick()
        # Asymmetric breath: (0.5+0.5*tri)^1.5-ish via squaring
        env = 0.5 + 0.5 * tri
        breath_mod = (1.0 - breath_depth) + breath_depth * env * env

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: 3 cascaded nasal/throat formants
            x = dry
            for k in range(3):
                x = s.formant[ch][k].process_sample(x)

            # Stage B: midrange presence peak
            x = s.presence[ch].process_sample(x)

            # Stage C: breath envelope gate
            x = x * breath_mod

            # Stage D: soft tanh saturation
            wet = math.tanh(x * drive) / drive

            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
