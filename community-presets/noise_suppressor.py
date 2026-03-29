import numpy as np
import math
from conjuredsp.params import db, time_ms
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "threshold": db(-80, -20, default=-50),
    "reduction": db(-60, 0, default=-30),
    "attack":    time_ms(min=0.1, max=5, default=0.5),
    "release":   time_ms(min=10, max=500, default=50),
}

_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Noise Suppressor — intelligent noise gate for guitar/bass.

    A smooth, musical noise gate designed for guitar rigs. Fast
    attack preserves pick transients, adjustable release prevents
    choppy cutoffs, and the reduction control allows partial
    attenuation instead of hard silence. Placed after distortion
    in the chain, it tames amplifier and pedal noise during pauses.
    Think ISP Decimator or Boss NS-2.

    Params:
        threshold: Gate open threshold (-80 to -20 dB)
        reduction: Maximum noise reduction (-60 to 0 dB)
        attack:    Gate open speed (0.1–5 ms)
        release:   Gate close speed (10–500 ms)
    """
    global _envelope

    thresh = db_to_gain(params["threshold"])
    reduction = db_to_gain(params["reduction"])
    att = smooth_coeff(params["attack"], sample_rate)
    rel = smooth_coeff(params["release"], sample_rate)

    for i in range(frame_count):
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        if peak > _envelope:
            _envelope = att * _envelope + (1.0 - att) * peak
        else:
            _envelope = rel * _envelope + (1.0 - rel) * peak

        if _envelope > thresh:
            gain = 1.0
        else:
            # Smooth transition from full signal to reduced
            ratio = _envelope / (thresh + 1e-30)
            gain = reduction + (1.0 - reduction) * ratio

        for ch in range(len(inputs)):
            outputs[ch][i] = inputs[ch][i] * gain
