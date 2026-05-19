import numpy as np
import math
from conjuredsp.params import db, freq, param
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "threshold": db(-60, -10, default=-35),
    "crossover": freq(min=200, max=5000, default=1000),
    "mode":      param(0, 1, default=0.5),
    "release":   param(10, 500, unit="ms", default=50),
}

_lp = None
_hp = None
_env_lo = 0.0
_env_hi = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Spectral Gate — frequency-dependent noise gate.

    Gates the low and high frequency bands independently based on
    their individual levels. When mode is low (0), only passes
    frequencies whose band is above the threshold — allowing loud
    bass to pass while gating quiet highs, or vice versa. Creates
    spectral thinning effects and frequency-selective noise reduction.
    Used in sound design, drum processing, and creative mixing.

    Params:
        threshold: Gate threshold per band (-60 to -10 dB)
        crossover: Split frequency between bands (200–5000 Hz)
        mode:      Gate behavior (0 = independent, 1 = crossfade)
        release:   Gate release time (10–500 ms)
    """
    global _lp, _hp, _env_lo, _env_hi

    thresh = db_to_gain(params["threshold"])
    xover = params["crossover"]
    mode = params["mode"]
    rel = smooth_coeff(params["release"], sample_rate)

    n_ch = len(inputs)

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(xover, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(xover, 0.7, sample_rate))

    for i in range(frame_count):
        lo_sum = 0.0
        hi_sum = 0.0

        for ch in range(n_ch):
            x = inputs[ch][i]
            lo = _lp[ch].process_sample(x)
            hi = _hp[ch].process_sample(x)
            lo_sum += abs(lo)
            hi_sum += abs(hi)

        lo_sum /= n_ch
        hi_sum /= n_ch

        # Independent envelope followers
        _env_lo = max(lo_sum, rel * _env_lo + (1.0 - rel) * lo_sum)
        _env_hi = max(hi_sum, rel * _env_hi + (1.0 - rel) * hi_sum)

        # Gate gains
        lo_gate = 1.0 if _env_lo > thresh else _env_lo / (thresh + 1e-10)
        hi_gate = 1.0 if _env_hi > thresh else _env_hi / (thresh + 1e-10)

        for ch in range(n_ch):
            x = inputs[ch][i]
            lo = _lp[ch].process_sample(x)
            hi = _hp[ch].process_sample(x)

            outputs[ch][i] = lo * lo_gate + hi * hi_gate
