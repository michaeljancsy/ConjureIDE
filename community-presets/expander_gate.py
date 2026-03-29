import numpy as np
import math
from conjuredsp.params import db, time_ms, param
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "threshold": db(-60, -10, default=-40),
    "ratio":     param(2, 20, unit=":1", default=8),
    "attack":    time_ms(min=0.1, max=10, default=0.5),
    "release":   time_ms(min=10, max=1000, default=100),
    "range":     db(-80, 0, default=-40),
}

_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Expander / Gate — downward expansion for noise reduction.

    Reduces the level of signals below the threshold, making quiet
    parts even quieter. At high ratios, acts as a noise gate that
    silences the signal when it drops below threshold. The range
    control limits how much attenuation is applied. Used to clean
    up drum bleed, reduce amplifier noise, and tighten recordings.

    Params:
        threshold: Level below which expansion begins (-60 to -10 dB)
        ratio:     Expansion ratio (2:1 = gentle, 20:1 = hard gate)
        attack:    How fast the gate opens (0.1–10 ms)
        release:   How fast the gate closes (10–1000 ms)
        range:     Maximum attenuation (-80 to 0 dB)
    """
    global _envelope

    threshold = db_to_gain(params["threshold"])
    exp_ratio = params["ratio"]
    att = smooth_coeff(params["attack"], sample_rate)
    rel = smooth_coeff(params["release"], sample_rate)
    range_gain = db_to_gain(params["range"])

    for i in range(frame_count):
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        if peak > _envelope:
            _envelope = att * _envelope + (1.0 - att) * peak
        else:
            _envelope = rel * _envelope + (1.0 - rel) * peak

        if _envelope < threshold and _envelope > 1e-30:
            db_below = 20.0 * math.log10(threshold / _envelope)
            db_reduction = db_below * (1.0 - 1.0 / exp_ratio)
            gain = 10.0 ** (-db_reduction / 20.0)
            gain = max(gain, range_gain)
        else:
            gain = 1.0

        for ch in range(len(inputs)):
            outputs[ch][i] = inputs[ch][i] * gain
