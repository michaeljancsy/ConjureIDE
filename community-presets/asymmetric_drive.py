import numpy as np
import math
from conjuredsp.params import param, db, mix
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "gain":   db(0, 30, default=12),
    "tone":   param(0, 1, default=0.6),
    "mix":    mix(default=1.0),
}

_hp_filters = None
_lp_filters = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Transparent Overdrive — Klon Centaur-inspired asymmetric clipping.

    Uses asymmetric soft clipping where the positive half clips gently
    while the negative half clips harder, producing a mix of even and
    odd harmonics. A pre-highpass removes mud, and the tone control
    blends between the clipped and clean signal at different frequencies.
    Famous for "transparent" overdrive that preserves the instrument's character.

    Params:
        gain: Drive amount (0–30 dB)
        tone: Brightness control (0 = dark, 1 = bright)
        mix:  Clean/drive blend
    """
    global _hp_filters, _lp_filters

    gain = db_to_gain(params["gain"])
    tone = params["tone"]
    wet_mix = params["mix"]

    if _hp_filters is None:
        _hp_filters = [Biquad() for _ in range(2)]
        _lp_filters = [Biquad() for _ in range(2)]

    for ch in range(len(inputs)):
        hp_coeffs = BiquadCoeffs.highpass(120.0, 0.7, sample_rate)
        _hp_filters[ch].set_coeffs(hp_coeffs)

        lp_freq = 2000.0 + tone * 10000.0
        lp_coeffs = BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate)
        _lp_filters[ch].set_coeffs(lp_coeffs)

        for i in range(frame_count):
            x = _hp_filters[ch].process_sample(inputs[ch][i])
            x *= gain

            # Asymmetric clipping
            if x >= 0:
                y = math.tanh(x * 0.8)
            else:
                y = math.tanh(x * 1.5) * 0.7

            y = _lp_filters[ch].process_sample(y)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
