import numpy as np
import math
from conjuredsp.params import db, ratio, time_ms
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "low_thresh":  db(-40, 0, default=-20),
    "mid_thresh":  db(-40, 0, default=-18),
    "high_thresh": db(-40, 0, default=-15),
    "ratio":       ratio(2, 20, default=4),
    "attack":      time_ms(min=0.5, max=50, default=5),
    "release":     time_ms(min=10, max=500, default=80),
}

_lp = None
_hp = None
_bp_lp = None
_bp_hp = None
_env = [0.0, 0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Multi-Band Compressor — 3-band independent compression.

    Splits the signal into low (<250 Hz), mid (250–2500 Hz), and
    high (>2500 Hz) bands and compresses each independently. This
    prevents bass transients from pumping the entire mix and allows
    precise dynamic control per frequency range. Essential for
    mastering, bus processing, and taming complex mixes.

    Params:
        low_thresh:  Bass compression threshold (-40 to 0 dB)
        mid_thresh:  Mid compression threshold (-40 to 0 dB)
        high_thresh: Treble compression threshold (-40 to 0 dB)
        ratio:       Compression ratio for all bands (2:1–20:1)
        attack:      Attack time (0.5–50 ms)
        release:     Release time (10–500 ms)
    """
    global _lp, _hp, _bp_lp, _bp_hp, _env

    thresholds = [
        db_to_gain(params["low_thresh"]),
        db_to_gain(params["mid_thresh"]),
        db_to_gain(params["high_thresh"]),
    ]
    comp_ratio = params["ratio"]
    att = smooth_coeff(params["attack"], sample_rate)
    rel = smooth_coeff(params["release"], sample_rate)

    n_ch = len(inputs)

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]
        _bp_lp = [Biquad() for _ in range(n_ch)]
        _bp_hp = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(250.0, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(2500.0, 0.7, sample_rate))
        _bp_lp[ch].set_coeffs(BiquadCoeffs.lowpass(2500.0, 0.7, sample_rate))
        _bp_hp[ch].set_coeffs(BiquadCoeffs.highpass(250.0, 0.7, sample_rate))

    for i in range(frame_count):
        for ch in range(n_ch):
            x = inputs[ch][i]

            bands = [
                _lp[ch].process_sample(x),
                _bp_lp[ch].process_sample(_bp_hp[ch].process_sample(x)),
                _hp[ch].process_sample(x),
            ]

            out = 0.0
            for b in range(3):
                level = abs(bands[b])

                if level > _env[b]:
                    _env[b] = att * _env[b] + (1.0 - att) * level
                else:
                    _env[b] = rel * _env[b] + (1.0 - rel) * level

                gain = 1.0
                if _env[b] > thresholds[b]:
                    db_over = 20.0 * math.log10(_env[b] / thresholds[b] + 1e-30)
                    db_red = db_over * (1.0 - 1.0 / comp_ratio)
                    gain = 10.0 ** (-db_red / 20.0)

                out += bands[b] * gain

            outputs[ch][i] = out
