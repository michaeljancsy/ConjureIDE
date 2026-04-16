# Acid Sermon — a televangelist sermon corroding through the speaker.
#
# Sin-based wavefolder (y = sin(π/2 · x · drive) — folds rather than soft-
# saturates when driven past unity) → 3 static formant peaks (700 / 1400 /
# 2500 Hz) whose amplitudes are modulated by 3 sub-Hz LFOs (0.11 / 0.17 /
# 0.23 Hz) → midrange presence peak (1800 Hz, +8 dB) → hard clip ceiling
# (aggressive clipping, NOT soft tanh) → dry no-reverb close space → mix.
#
# First preset using a wavefolder and hard clip instead of soft tanh;
# aggressive dry mids instead of a reverb tail. The corrosion IS the sound.
#
# Params:
#   fold     (pct) — wavefolder drive
#   sermon   (pct) — formant amplitude modulation depth
#   presence (pct) — midrange presence peak gain
#   crust    (pct) — hard clip ceiling (lower → more clipping)
#   mix            — wet/dry blend

import math
from conjuredsp import (mix, pct,
                        Biquad, BiquadCoeffs, LFO)

PARAMS = {
    "fold":     pct(default=55),
    "sermon":   pct(default=50),
    "presence": pct(default=60),
    "crust":    pct(default=55),
    "mix":      mix(default=0.6),
}

FORMANT_HZ = [700.0, 1400.0, 2500.0]
FORMANT_LFO_HZ = [0.11, 0.17, 0.23]
PRESENCE_HZ = 1800.0

_st = None
_sr = None


class _S:
    def __init__(self, sr, nch):
        self.formant = [[Biquad() for _ in range(3)] for _ in range(nch)]
        self.formant_lfo = [LFO(sr, freq=FORMANT_LFO_HZ[k], waveform="sine")
                            for k in range(3)]
        self.presence = [Biquad() for _ in range(nch)]


def process(inputs, outputs, frame_count, sample_rate, params):
    global _st, _sr
    nch = len(inputs)
    if _st is None or _sr != sample_rate:
        _st = _S(sample_rate, nch)
        _sr = sample_rate

    s = _st
    fold = params["fold"] / 100.0
    sermon = params["sermon"] / 100.0
    presence = params["presence"] / 100.0
    crust = params["crust"] / 100.0
    mx = params["mix"]

    formant_c = [BiquadCoeffs.peak(FORMANT_HZ[k], 4.0, 8.0, sample_rate)
                 for k in range(3)]
    presence_c = BiquadCoeffs.peak(PRESENCE_HZ, 2.5, 3.0 + 6.0 * presence,
                                    sample_rate)
    for ch in range(nch):
        for k in range(3):
            s.formant[ch][k].set_coeffs(formant_c[k])
        s.presence[ch].set_coeffs(presence_c)

    drive = 1.0 + 5.0 * fold
    fold_scale = math.pi * 0.5 * drive
    formant_depth = 0.6 * sermon
    # Hard clip ceiling — more crust → lower ceiling → more clipping
    clip_ceil = 1.0 - 0.7 * crust

    for i in range(frame_count):
        lm = [s.formant_lfo[k].tick() for k in range(3)]
        fm = [(1.0 - formant_depth) + formant_depth * (0.5 + 0.5 * lm[k])
              for k in range(3)]

        for ch in range(nch):
            dry = float(inputs[ch][i])

            # Stage A: sin-based wavefolder
            folded = math.sin(dry * fold_scale)

            # Stage B: 3 static formant peaks with LFO-modulated mix
            f0 = s.formant[ch][0].process_sample(folded) * fm[0]
            f1 = s.formant[ch][1].process_sample(folded) * fm[1]
            f2 = s.formant[ch][2].process_sample(folded) * fm[2]
            voiced = (f0 + f1 + f2) / 3.0

            # Stage C: midrange presence
            presenced = s.presence[ch].process_sample(voiced)

            # Stage D: hard clip
            if presenced > clip_ceil:
                wet = clip_ceil
            elif presenced < -clip_ceil:
                wet = -clip_ceil
            else:
                wet = presenced

            outputs[ch][i] = dry * (1.0 - mx) + wet * mx
