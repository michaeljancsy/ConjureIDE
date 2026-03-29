import numpy as np
import math
from conjuredsp.params import freq, param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "pitch":     freq(min=200, max=8000, default=1000),
    "harmonics": param(1, 8, default=4),
    "resonance": param(5, 30, unit="Q", default=15),
    "mix":       mix(default=0.5),
}

_filters = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Crystal Resonance — high-Q harmonic resonator bank.

    Multiple ultra-sharp bandpass filters tuned to harmonic
    intervals of a fundamental pitch. Input audio excites the
    resonators, producing bell-like, crystalline ringing. More
    harmonics = more complex, metallic tones. Use for percussion
    processing, creating pitched textures from noise, or adding
    harmonic complexity to any sound. Inspired by physical modeling
    of struck metal.

    Params:
        pitch:     Fundamental resonant pitch (200–8000 Hz)
        harmonics: Number of harmonic resonators (1–8)
        resonance: Filter sharpness / ring time (Q 5–30)
        mix:       Wet/dry blend
    """
    global _filters

    pitch_hz = params["pitch"]
    n_harmonics = int(params["harmonics"])
    q = params["resonance"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _filters is None:
        _filters = [[Biquad() for _ in range(8)] for _ in range(n_ch)]

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i]
            wet = 0.0

            for h in range(n_harmonics):
                harmonic_freq = pitch_hz * (h + 1)
                if harmonic_freq >= sample_rate * 0.45:
                    break

                coeffs = BiquadCoeffs.bandpass(harmonic_freq, q, sample_rate)
                _filters[ch][h].set_coeffs(coeffs)

                # Higher harmonics get progressively quieter
                level = 1.0 / (h + 1)
                wet += _filters[ch][h].process_sample(x) * q * level

            wet /= max(n_harmonics, 1)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + wet * wet_mix
