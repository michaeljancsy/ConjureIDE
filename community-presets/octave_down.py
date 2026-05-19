import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "octave1": param(0, 1, default=0.7),
    "octave2": param(0, 1, default=0.3),
    "tone":    param(0, 1, default=0.5),
    "mix":     mix(default=0.5),
}

_phase = 0.0
_prev_sign = 1.0
_lp = None
_square1 = 1.0
_square2 = 1.0
_toggle = False


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Octave Down — sub-octave generator (Boss OC-2 style).

    Generates one and two octaves below the input by tracking
    zero crossings and creating square waves at half and quarter
    the input frequency. A tone filter smooths the square waves
    into something more sinusoidal. The classic sub-octave effect
    for bass guitar, funk, and doom metal. Tracks best with
    monophonic input.

    Params:
        octave1: Level of -1 octave (0–1)
        octave2: Level of -2 octaves (0–1)
        tone:    Smoothing filter (0 = buzzy square, 1 = smooth sine)
        mix:     Dry + sub blend
    """
    global _phase, _prev_sign, _lp, _square1, _square2, _toggle

    oct1_level = params["octave1"]
    oct2_level = params["octave2"]
    tone = params["tone"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]

    lp_freq = 200.0 + tone * 2000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]

            # Zero crossing detection (use first channel for tracking)
            if ch == 0:
                current_sign = 1.0 if x >= 0 else -1.0
                if current_sign != _prev_sign:
                    _square1 = -_square1  # divide by 2
                    _toggle = not _toggle
                    if _toggle:
                        _square2 = -_square2  # divide by 4
                    _prev_sign = current_sign

            # Generate sub octave signals
            sub = _square1 * oct1_level + _square2 * oct2_level

            # Scale by input envelope for tracking
            env = abs(x)
            sub *= env

            # Tone filter
            sub = _lp[ch].process_sample(sub)

            outputs[ch][i] = x * (1.0 - wet_mix) + (x + sub) * wet_mix
