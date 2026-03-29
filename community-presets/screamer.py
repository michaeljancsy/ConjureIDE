import numpy as np
import math
from conjuredsp.params import param, db, mix
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "drive": param(1, 30, unit="x", default=8),
    "tone":  param(0, 1, default=0.6),
    "level": db(-20, 6, default=0),
}

_hp = None
_mid_boost = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Screamer — Tube Screamer-inspired mid-boosted overdrive.

    The legendary green pedal: a mid-hump EQ into symmetrical soft
    clipping. Cuts bass before distortion to prevent mud, boosts mids
    for cut and sustain, rolls off fizzy highs after clipping. The
    most popular overdrive pedal ever made — essential for blues,
    rock, and pushing a tube amp into breakup.

    Params:
        drive: Clipping drive (1–30x)
        tone:  Post-clip brightness (0 = dark, 1 = bright)
        level: Output level (-20 to +6 dB)
    """
    global _hp, _mid_boost, _lp

    drive = params["drive"]
    tone = params["tone"]
    level = db_to_gain(params["level"])

    n_ch = len(inputs)

    if _hp is None:
        _hp = [Biquad() for _ in range(n_ch)]
        _mid_boost = [Biquad() for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        # Pre-clipping: cut lows, boost mids
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(200.0, 0.7, sample_rate))
        _mid_boost[ch].set_coeffs(BiquadCoeffs.peak(800.0, 1.5, 6.0, sample_rate))

        # Post-clipping tone
        lp_freq = 2000.0 + tone * 8000.0
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]
            x = _hp[ch].process_sample(x)
            x = _mid_boost[ch].process_sample(x)
            x *= drive

            # Symmetric soft clip (diode pair)
            y = math.tanh(x)

            y = _lp[ch].process_sample(y)

            outputs[ch][i] = y * level
