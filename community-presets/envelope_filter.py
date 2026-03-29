import numpy as np
import math
from conjuredsp.params import param, freq, choice
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import smooth_coeff

PARAMS = {
    "sensitivity": param(1, 20, unit="x", default=8),
    "min_freq":    freq(min=100, max=1000, default=200),
    "max_freq":    freq(min=2000, max=10000, default=5000),
    "resonance":   param(1, 15, unit="Q", default=5),
    "attack":      param(1, 50, unit="ms", default=5),
    "release":     param(10, 500, unit="ms", default=80),
}

_filters = None
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Envelope Filter — auto-wah / Mu-Tron III inspired.

    The filter frequency follows the input amplitude: play harder
    and the filter opens up, play softly and it closes. The signature
    funky "wah" sound without a foot pedal. The Mu-Tron III defined
    the funk guitar/bass sound — think Bootsy Collins, Jerry Garcia,
    and Stevie Wonder's clavinet.

    Params:
        sensitivity: How much input level drives the filter (1–20x)
        min_freq:    Filter frequency at lowest input level
        max_freq:    Filter frequency at highest input level
        resonance:   Filter peak sharpness (Q)
        attack:      How fast the filter opens (1–50 ms)
        release:     How fast the filter closes (10–500 ms)
    """
    global _filters, _envelope

    sensitivity = params["sensitivity"]
    min_f = params["min_freq"]
    max_f = params["max_freq"]
    q = params["resonance"]
    attack_ms = params["attack"]
    release_ms = params["release"]

    n_ch = len(inputs)

    if _filters is None:
        _filters = [Biquad() for _ in range(n_ch)]

    att_coeff = smooth_coeff(attack_ms, sample_rate)
    rel_coeff = smooth_coeff(release_ms, sample_rate)

    log_min = math.log(min_f)
    log_max = math.log(max_f)

    for i in range(frame_count):
        # Peak detect
        peak = 0.0
        for ch in range(n_ch):
            peak = max(peak, abs(inputs[ch][i]))

        peak *= sensitivity

        # Envelope follower
        if peak > _envelope:
            _envelope = att_coeff * _envelope + (1.0 - att_coeff) * peak
        else:
            _envelope = rel_coeff * _envelope + (1.0 - rel_coeff) * peak

        # Map envelope to frequency (log scale)
        env_clamped = min(1.0, _envelope)
        sweep_freq = math.exp(log_min + (log_max - log_min) * env_clamped)
        sweep_freq = min(sweep_freq, sample_rate * 0.45)

        coeffs = BiquadCoeffs.bandpass(sweep_freq, q, sample_rate)
        for ch in range(n_ch):
            _filters[ch].set_coeffs(coeffs)
            outputs[ch][i] = _filters[ch].process_sample(inputs[ch][i]) * q * 0.5
