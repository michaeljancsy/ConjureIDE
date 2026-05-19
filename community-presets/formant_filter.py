import numpy as np
import math
from conjuredsp.params import param, choice
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "vowel":     choice("A", "E", "I", "O", "U", default="A"),
    "resonance": param(1, 20, unit="Q", default=8),
    "shift":     param(-12, 12, unit="st", default=0),
}

# Formant frequencies (F1, F2, F3) for each vowel
VOWEL_FORMANTS = {
    0: (800, 1200, 2500),   # A — "ah"
    1: (350, 2000, 2800),   # E — "eh"
    2: (270, 2300, 3000),   # I — "ee"
    3: (450, 800, 2500),    # O — "oh"
    4: (325, 700, 2500),    # U — "oo"
}

_filters = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Formant Filter — vowel-shaping resonant filter.

    Applies three bandpass filters at vowel formant frequencies,
    making any sound "speak" a vowel. Each vowel (A, E, I, O, U)
    has characteristic resonant peaks that define its sound. The
    shift control transposes all formants up or down in pitch.
    Used for vocal-like synth patches, talk box simulation, and
    creative sound design.

    Params:
        vowel:     Which vowel sound (A, E, I, O, U)
        resonance: Formant peak sharpness (1–20)
        shift:     Formant pitch shift in semitones (-12 to +12)
    """
    global _filters

    vowel_idx = int(params["vowel"])
    q = params["resonance"]
    shift_st = params["shift"]

    n_ch = len(inputs)

    if _filters is None:
        _filters = [[Biquad() for _ in range(3)] for _ in range(n_ch)]

    formants = VOWEL_FORMANTS.get(vowel_idx, VOWEL_FORMANTS[0])

    # Apply pitch shift
    shift_ratio = 2.0 ** (shift_st / 12.0)

    for ch in range(n_ch):
        for f_idx in range(3):
            freq = formants[f_idx] * shift_ratio
            freq = max(50.0, min(freq, sample_rate * 0.45))
            coeffs = BiquadCoeffs.bandpass(freq, q, sample_rate)
            _filters[ch][f_idx].set_coeffs(coeffs)

        for i in range(frame_count):
            x = inputs[ch][i]

            # Sum all formant bands
            y = 0.0
            for f_idx in range(3):
                y += _filters[ch][f_idx].process_sample(x)

            # Normalize
            outputs[ch][i] = y * 0.4
