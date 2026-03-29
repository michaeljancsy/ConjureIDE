import numpy as np
import math
import random
from conjuredsp.params import param, freq
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "rate":      param(0.5, 30, unit="Hz", default=4),
    "min_freq":  freq(min=100, max=2000, default=200),
    "max_freq":  freq(min=2000, max=16000, default=8000),
    "resonance": param(0.5, 15, unit="Q", default=5),
}

_filters = None
_phase = 0.0
_current_freq = 1000.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Sample & Hold Filter — random stepped filter modulation.

    A bandpass filter whose frequency jumps to random values at a
    clock rate. Each "tick" of the S&H clock picks a new random
    frequency between min and max. Creates bubbly, robotic, or
    glitchy filter textures. Classic in electronic music, synth
    sequences, and experimental sound design.

    Params:
        rate:      Clock rate — how often the filter jumps (0.5–30 Hz)
        min_freq:  Minimum random frequency (100–2000 Hz)
        max_freq:  Maximum random frequency (2–16 kHz)
        resonance: Filter resonance/Q (0.5–15)
    """
    global _filters, _phase, _current_freq

    rate = params["rate"]
    min_f = params["min_freq"]
    max_f = params["max_freq"]
    q = params["resonance"]

    n_ch = len(inputs)

    if _filters is None:
        _filters = [Biquad() for _ in range(n_ch)]

    inc = rate / sample_rate

    for i in range(frame_count):
        old_phase = _phase
        _phase = (_phase + inc) % 1.0

        # Trigger new random frequency on phase wrap
        if _phase < old_phase:
            # Log-uniform random frequency
            log_min = math.log(min_f)
            log_max = math.log(max_f)
            _current_freq = math.exp(random.uniform(log_min, log_max))

        coeffs = BiquadCoeffs.bandpass(_current_freq, q, sample_rate)
        for ch in range(n_ch):
            _filters[ch].set_coeffs(coeffs)
            outputs[ch][i] = _filters[ch].process_sample(inputs[ch][i]) * q
