import numpy as np
import math
from conjuredsp.params import param, freq, choice
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "rate":      param(0.01, 2, unit="Hz", default=0.1),
    "min_freq":  freq(min=50, max=500, default=100),
    "max_freq":  freq(min=2000, max=16000, default=8000),
    "resonance": param(0.5, 20, unit="Q", default=5),
    "type":      choice("Low", "Band", "High", default="Low"),
}

_filters = None
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Resonant Sweep — slow automated filter sweep.

    A resonant filter that slowly sweeps between two frequencies.
    Creates evolving, cinematic filter effects without needing
    automation or an LFO pedal. At slow rates with high resonance,
    produces hypnotic, meditative textures. At faster rates, creates
    wah-like effects. Great for ambient pads, DJ transitions, and
    building tension in electronic music.

    Params:
        rate:      Sweep speed (0.01–2 Hz)
        min_freq:  Bottom of sweep range
        max_freq:  Top of sweep range
        resonance: Filter resonance (Q)
        type:      Filter type (Low/Band/High pass)
    """
    global _filters, _phase

    rate = params["rate"]
    min_f = params["min_freq"]
    max_f = params["max_freq"]
    q = params["resonance"]
    ftype = int(params["type"])

    n_ch = len(inputs)

    if _filters is None:
        _filters = [Biquad() for _ in range(n_ch)]

    log_min = math.log(min_f)
    log_max = math.log(max_f)
    two_pi = 2.0 * math.pi

    for i in range(frame_count):
        # Triangle LFO for smooth sweep
        t = _phase
        lfo = 4.0 * abs(t - 0.5) - 1.0  # triangle -1 to 1
        sweep = 0.5 + 0.5 * lfo  # 0 to 1

        sweep_freq = math.exp(log_min + (log_max - log_min) * sweep)
        sweep_freq = min(sweep_freq, sample_rate * 0.45)

        if ftype == 0:
            coeffs = BiquadCoeffs.lowpass(sweep_freq, q, sample_rate)
        elif ftype == 1:
            coeffs = BiquadCoeffs.bandpass(sweep_freq, q, sample_rate)
        else:
            coeffs = BiquadCoeffs.highpass(sweep_freq, q, sample_rate)

        for ch in range(n_ch):
            _filters[ch].set_coeffs(coeffs)
            outputs[ch][i] = _filters[ch].process_sample(inputs[ch][i])

        _phase = (_phase + rate / sample_rate) % 1.0
