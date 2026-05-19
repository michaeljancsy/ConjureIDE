import numpy as np
import math
from conjuredsp.params import param, freq, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "frequency": freq(min=1000, max=10000, default=3000),
    "harmonics": param(0, 1, default=0.5),
    "mix":       mix(default=0.3),
}

_hp_filters = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Harmonic Exciter — Aphex Aural Exciter-inspired enhancer.

    Generates new harmonics by filtering out the high-frequency content,
    applying soft saturation to create harmonics, then mixing the
    harmonics back with the original. Adds presence and sparkle without
    simply boosting existing frequencies. Classic studio trick for
    vocals, acoustic guitars, and dull mixes.

    Params:
        frequency: Crossover frequency — harmonics generated above this (1–10 kHz)
        harmonics: Saturation intensity for harmonic generation (0–1)
        mix:       Amount of generated harmonics to blend in
    """
    global _hp_filters

    crossover = params["frequency"]
    harm_drive = 1.0 + params["harmonics"] * 10.0
    wet_mix = params["mix"]

    if _hp_filters is None:
        _hp_filters = [Biquad() for _ in range(2)]

    for ch in range(len(inputs)):
        coeffs = BiquadCoeffs.highpass(crossover, 0.7, sample_rate)
        _hp_filters[ch].set_coeffs(coeffs)

        for i in range(frame_count):
            x = inputs[ch][i]

            # Extract highs
            highs = _hp_filters[ch].process_sample(x)

            # Generate harmonics via soft saturation
            harmonics = math.tanh(highs * harm_drive) - highs

            # Blend harmonics back with original
            outputs[ch][i] = x + harmonics * wet_mix
