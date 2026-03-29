import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "drive":     param(0, 20, unit="dB", default=6),
    "bias":      param(0, 1, default=0.5),
    "mix":       mix(default=0.8),
}

_filters = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tape Saturation — analog reel-to-reel tape warmth.

    Models the magnetic hysteresis of recording tape: gentle compression,
    soft high-frequency rolloff, and subtle odd-harmonic generation.
    The bias control adjusts the character from under-biased (more
    distortion, thinner) to over-biased (cleaner, darker).

    Params:
        drive: Input gain into the tape (0–20 dB)
        bias:  Tape bias — low = gritty, high = smooth/dark
        mix:   Wet/dry blend
    """
    global _filters

    drive_db = params["drive"]
    bias = params["bias"]
    wet_mix = params["mix"]

    drive_gain = 10.0 ** (drive_db / 20.0)

    # Tape head bump around 80 Hz + high rolloff based on bias
    rolloff_freq = 4000.0 + bias * 12000.0

    if _filters is None:
        _filters = [Biquad(), Biquad()]

    for ch in range(len(inputs)):
        coeffs = BiquadCoeffs.lowpass(rolloff_freq, 0.7, sample_rate)
        _filters[ch].set_coeffs(coeffs)

        for i in range(frame_count):
            x = inputs[ch][i] * drive_gain

            # Tape saturation curve — softer than tanh
            # Approximates magnetic hysteresis
            if abs(x) < 1.0:
                y = x - (x ** 3) / 3.0
            else:
                y = 2.0 / 3.0 if x > 0 else -2.0 / 3.0

            # Bias affects the asymmetry
            y += 0.05 * (bias - 0.5) * (x * x)

            # Head bump / rolloff
            y = _filters[ch].process_sample(y)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
