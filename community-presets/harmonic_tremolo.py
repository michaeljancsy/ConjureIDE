import numpy as np
import math
from conjuredsp.params import param
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "rate":    param(1, 12, unit="Hz", default=5),
    "depth":   param(0, 1, default=0.7),
    "crossover": param(500, 2000, unit="Hz", default=800),
}

_phase = 0.0
_lp = None
_hp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Harmonic Tremolo — Fender Brownface-style frequency-split tremolo.

    Unlike standard tremolo that modulates the whole signal, harmonic
    tremolo splits the signal into low and high bands and modulates
    them with opposite LFO phases. When lows get louder, highs get
    quieter and vice versa. Creates a lush, pulsating, almost
    phaser-like shimmer. The signature sound of early 60s Fender amps
    before they switched to standard tremolo.

    Params:
        rate:      Tremolo speed (1–12 Hz)
        depth:     Modulation depth (0–1)
        crossover: Low/high split frequency (500–2000 Hz)
    """
    global _phase, _lp, _hp

    rate = params["rate"]
    depth = params["depth"]
    xover = params["crossover"]

    n_ch = len(inputs)

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    two_pi = 2.0 * math.pi

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(xover, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(xover, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]
            low = _lp[ch].process_sample(x)
            high = _hp[ch].process_sample(x)

            # Opposite-phase modulation
            mod = math.sin(two_pi * _phase)
            low_gain = 1.0 - depth * 0.5 * (1.0 + mod)
            high_gain = 1.0 - depth * 0.5 * (1.0 - mod)

            outputs[ch][i] = low * low_gain + high * high_gain

            if ch == 0:
                _phase = (_phase + rate / sample_rate) % 1.0
