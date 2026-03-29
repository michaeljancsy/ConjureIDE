import numpy as np
import math
from conjuredsp.params import param, freq
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import smooth_coeff

PARAMS = {
    "bands":   param(4, 16, default=8),
    "attack":  param(1, 50, unit="ms", default=5),
    "release": param(10, 200, unit="ms", default=50),
    "shift":   param(-12, 12, unit="st", default=0),
}

_analysis_filters = None
_synthesis_filters = None
_envelopes = None
NUM_BANDS = 16


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Vocoder — channel vocoder for robotic voice.

    Splits the input into frequency bands, extracts the amplitude
    envelope of each band, and applies those envelopes to a
    synthesized carrier (derived from the input itself via
    rectification). Creates the classic robotic/synthetic voice
    effect. The shift control transposes the synthesis bands for
    pitch-shifted vocoder effects. Best with vocal or speech input.

    Params:
        bands:   Number of frequency bands (4–16)
        attack:  Envelope attack speed (1–50 ms)
        release: Envelope release speed (10–200 ms)
        shift:   Synthesis band pitch shift in semitones (-12 to +12)
    """
    global _analysis_filters, _synthesis_filters, _envelopes

    n_bands = int(params["bands"])
    att = smooth_coeff(params["attack"], sample_rate)
    rel = smooth_coeff(params["release"], sample_rate)
    shift_st = params["shift"]

    n_ch = len(inputs)

    if _analysis_filters is None:
        _analysis_filters = [[Biquad() for _ in range(NUM_BANDS)] for _ in range(n_ch)]
        _synthesis_filters = [[Biquad() for _ in range(NUM_BANDS)] for _ in range(n_ch)]
        _envelopes = [0.0] * NUM_BANDS

    # Band frequencies spaced logarithmically
    min_f = 100.0
    max_f = min(12000.0, sample_rate * 0.45)
    shift_ratio = 2.0 ** (shift_st / 12.0)

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i]

            # Generate carrier: rectified + noisy version of input
            carrier = abs(x) + x * x * 0.5

            out = 0.0
            for b in range(n_bands):
                # Log-spaced center frequency
                t = b / max(n_bands - 1, 1)
                center = min_f * (max_f / min_f) ** t

                q = 3.0 + n_bands * 0.5  # higher Q with more bands

                # Analysis: extract band energy
                a_coeffs = BiquadCoeffs.bandpass(center, q, sample_rate)
                _analysis_filters[ch][b].set_coeffs(a_coeffs)
                band_signal = _analysis_filters[ch][b].process_sample(x)

                # Envelope follower (only on first channel)
                if ch == 0:
                    level = abs(band_signal) * q
                    if level > _envelopes[b]:
                        _envelopes[b] = att * _envelopes[b] + (1.0 - att) * level
                    else:
                        _envelopes[b] = rel * _envelopes[b] + (1.0 - rel) * level

                # Synthesis: filter carrier at (possibly shifted) frequency
                synth_freq = min(center * shift_ratio, sample_rate * 0.45)
                s_coeffs = BiquadCoeffs.bandpass(synth_freq, q, sample_rate)
                _synthesis_filters[ch][b].set_coeffs(s_coeffs)
                synth_band = _synthesis_filters[ch][b].process_sample(carrier)

                # Apply analysis envelope to synthesis band
                out += synth_band * _envelopes[b]

            outputs[ch][i] = out * 2.0 / n_bands
