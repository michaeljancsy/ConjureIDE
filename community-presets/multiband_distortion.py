import numpy as np
import math
from conjuredsp.params import param, freq
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "low_xover":  freq(min=100, max=500, default=250),
    "high_xover": freq(min=2000, max=8000, default=4000),
    "low_drive":  param(1, 20, unit="x", default=2),
    "mid_drive":  param(1, 20, unit="x", default=5),
    "high_drive": param(1, 20, unit="x", default=3),
}

_lp1 = None
_hp1 = None
_lp2 = None
_hp2 = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Multi-Band Distortion — independent distortion per frequency band.

    Splits the signal into low, mid, and high bands using crossover
    filters, applies different amounts of saturation to each band,
    then recombines. This prevents bass mud and harsh treble that
    plague full-range distortion. Essential for bass guitar, mastering,
    and electronic music production.

    Params:
        low_xover:  Low/mid crossover frequency
        high_xover: Mid/high crossover frequency
        low_drive:  Bass band distortion (1–20x)
        mid_drive:  Mid band distortion (1–20x)
        high_drive: Treble band distortion (1–20x)
    """
    global _lp1, _hp1, _lp2, _hp2

    low_freq = params["low_xover"]
    high_freq = params["high_xover"]
    low_drv = params["low_drive"]
    mid_drv = params["mid_drive"]
    high_drv = params["high_drive"]

    n_ch = len(inputs)

    if _lp1 is None:
        _lp1 = [Biquad() for _ in range(n_ch)]
        _hp1 = [Biquad() for _ in range(n_ch)]
        _lp2 = [Biquad() for _ in range(n_ch)]
        _hp2 = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _lp1[ch].set_coeffs(BiquadCoeffs.lowpass(low_freq, 0.7, sample_rate))
        _hp1[ch].set_coeffs(BiquadCoeffs.highpass(low_freq, 0.7, sample_rate))
        _lp2[ch].set_coeffs(BiquadCoeffs.lowpass(high_freq, 0.7, sample_rate))
        _hp2[ch].set_coeffs(BiquadCoeffs.highpass(high_freq, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]

            low = _lp1[ch].process_sample(x)
            rest = _hp1[ch].process_sample(x)
            mid = _lp2[ch].process_sample(rest)
            high = _hp2[ch].process_sample(rest)

            low = math.tanh(low * low_drv)
            mid = math.tanh(mid * mid_drv)
            high = math.tanh(high * high_drv)

            outputs[ch][i] = low + mid + high
