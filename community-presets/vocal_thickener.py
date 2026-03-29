import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "thickness": param(0, 1, default=0.5),
    "warmth":    param(0, 1, default=0.4),
    "air":       param(0, 1, default=0.3),
    "mix":       mix(default=0.5),
}

MAX_DELAY = 2048
_delays = None
_lp = None
_hs = None
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Vocal Thickener — chorus + saturation for rich vocals.

    Combines subtle chorus (for body), gentle saturation (for warmth),
    and a high-shelf "air" boost (for presence) — the three classic
    mixing tricks for thick, professional vocals in one preset.
    Designed to make thin or dry vocal takes sound polished and
    full. Essential for pop, R&B, and any vocal-forward production.

    Params:
        thickness: Chorus depth for vocal body (0–1)
        warmth:    Saturation for harmonics (0–1)
        air:       High-frequency presence boost (0–1)
        mix:       Effect blend
    """
    global _delays, _lp, _hs, _phase

    thickness = params["thickness"]
    warmth = params["warmth"]
    air = params["air"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]
        _hs = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _hs[ch].set_coeffs(BiquadCoeffs.highshelf(8000.0, 0.7, air * 6.0, sample_rate))

    for i in range(frame_count):
        mod = math.sin(two_pi * _phase) * thickness * 3.0
        delay = 8.0 + mod

        for ch in range(n_ch):
            x = inputs[ch][i]

            # Chorus for thickness
            _delays[ch].write(x)
            chorus = _delays[ch].read_cubic(max(1.0, delay))

            # Blend dry and chorus
            y = x * (1.0 - wet_mix * 0.5) + chorus * wet_mix * 0.5

            # Warmth via gentle saturation
            if warmth > 0:
                drive = 1.0 + warmth * 3.0
                y = math.tanh(y * drive) / drive * (drive * 0.7)

            # Air boost
            y = _hs[ch].process_sample(y)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix

        _phase = (_phase + 0.7 / sample_rate) % 1.0
