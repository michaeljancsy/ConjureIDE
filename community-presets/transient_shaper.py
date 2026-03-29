import numpy as np
import math
from conjuredsp.params import param, db
from conjuredsp.dsp import smooth_coeff, db_to_gain

PARAMS = {
    "attack":  db(-12, 12, default=0),
    "sustain": db(-12, 12, default=0),
    "speed":   param(5, 50, unit="ms", default=15),
}

_fast_env = 0.0
_slow_env = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Transient Shaper — attack and sustain design.

    Independently controls the attack (transient) and sustain (body)
    of a sound without traditional compression. Boost attack for
    punchier drums, cut attack for softer transients, boost sustain
    for fatter body, cut sustain for tighter decay. Works by comparing
    fast and slow envelope followers. The modern alternative to
    compression for drum mixing.

    Params:
        attack:  Transient boost/cut (-12 to +12 dB)
        sustain: Body/sustain boost/cut (-12 to +12 dB)
        speed:   Detector speed — lower = faster transient detection (5–50 ms)
    """
    global _fast_env, _slow_env

    attack_gain = db_to_gain(params["attack"])
    sustain_gain = db_to_gain(params["sustain"])
    speed_ms = params["speed"]

    fast_coeff = smooth_coeff(speed_ms * 0.2, sample_rate)
    slow_coeff = smooth_coeff(speed_ms * 3.0, sample_rate)

    for i in range(frame_count):
        # Peak detect across channels
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        # Dual envelope followers
        if peak > _fast_env:
            _fast_env = fast_coeff * _fast_env + (1.0 - fast_coeff) * peak
        else:
            _fast_env = fast_coeff * _fast_env + (1.0 - fast_coeff) * peak

        if peak > _slow_env:
            _slow_env = slow_coeff * _slow_env + (1.0 - slow_coeff) * peak
        else:
            _slow_env = slow_coeff * _slow_env + (1.0 - slow_coeff) * peak

        # Transient = fast > slow (attack phase)
        # Sustain = fast ≈ slow (steady state)
        diff = _fast_env - _slow_env

        if diff > 0:
            # Attack phase — apply attack gain
            gain = 1.0 + diff * (attack_gain - 1.0) * 5.0
        else:
            # Sustain phase — apply sustain gain
            gain = sustain_gain

        gain = max(0.01, min(gain, 10.0))

        for ch in range(len(inputs)):
            outputs[ch][i] = inputs[ch][i] * gain
