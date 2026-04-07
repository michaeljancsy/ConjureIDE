import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "static":    param(0, 1, default=0.3),
    "bandwidth": param(0, 1, default=0.5),
    "tone":      param(0, 1, default=0.3),
    "mix":       mix(default=1.0),
}

_rng_state = 12345

def _rng():
    global _rng_state
    _rng_state = (_rng_state * 1664525 + 1013904223) & 0xFFFFFFFF
    return _rng_state / 4294967296.0

_bp = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    AM Radio — vintage radio / broadcast simulation.

    Simulates the narrow bandwidth, distortion, and noise of an
    AM radio transmission. A tight bandpass filter restricts the
    frequency range, soft clipping adds transmitter compression,
    and noise simulates atmospheric static. The bandwidth control
    goes from barely intelligible to FM-quality. Great for vocal
    effects, vintage vibes, and transitions in music production.

    Params:
        static:    Background static / noise (0–1)
        bandwidth: Tuning quality / bandwidth (0 = narrow, 1 = wide)
        tone:      Brightness of the radio sound (0–1)
        mix:       Wet/dry blend
    """
    global _bp, _lp

    static = params["static"]
    bandwidth = params["bandwidth"]
    tone = params["tone"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _bp is None:
        _bp = [Biquad() for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    # Radio bandwidth: 200-5000 Hz range
    center = 1200.0 + tone * 1500.0
    q = 0.5 + (1.0 - bandwidth) * 5.0

    for ch in range(n_ch):
        _bp[ch].set_coeffs(BiquadCoeffs.bandpass(center, q, sample_rate))
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(3000.0 + bandwidth * 5000.0, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]

            # Bandpass to radio spectrum
            y = _bp[ch].process_sample(x) * q * 0.5
            y = _lp[ch].process_sample(y)

            # AM transmitter compression
            y = math.tanh(y * 3.0) * 0.5

            # Static noise
            y += (_rng() - 0.5) * static * 0.1

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
