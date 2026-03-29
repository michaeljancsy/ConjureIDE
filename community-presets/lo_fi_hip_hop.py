import numpy as np
import math
import random
from conjuredsp.params import param
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.buffers import DelayLine

PARAMS = {
    "vinyl":   param(0, 1, default=0.4),
    "warmth":  param(0, 1, default=0.6),
    "wobble":  param(0, 1, default=0.3),
    "bit_depth": param(8, 16, unit="bits", default=12),
}

_lp = None
_hp = None
_delays = None
_wow_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Lo-Fi Hip Hop — the study beats aesthetic.

    Combines all the hallmarks of lo-fi hip hop production: vinyl
    crackle, tape wobble, gentle bit reduction, and warm filtering.
    Cuts the harsh highs, adds analog warmth, introduces subtle
    pitch wobble, and layers in vinyl texture. Perfect for the
    "chill beats to study to" aesthetic — apply to any beat, keys,
    or sample for instant lo-fi vibes.

    Params:
        vinyl:     Vinyl crackle and surface noise (0–1)
        warmth:    Low-pass warmth / high cut (0–1)
        wobble:    Tape wow / pitch drift (0–1)
        bit_depth: Digital degradation (8–16 bits)
    """
    global _lp, _hp, _delays, _wow_phase

    vinyl = params["vinyl"]
    warmth = params["warmth"]
    wobble = params["wobble"]
    bit_depth = int(params["bit_depth"])

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]
        _delays = [DelayLine(1024) for _ in range(n_ch)]

    # Warmth = low pass
    lp_freq = 16000.0 - warmth * 10000.0

    levels = 2 ** bit_depth

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(40.0, 0.7, sample_rate))

    for i in range(frame_count):
        # Tape wobble
        wow = math.sin(two_pi * _wow_phase) * wobble * 3.0
        _wow_phase = (_wow_phase + 0.5 / sample_rate) % 1.0

        for ch in range(n_ch):
            x = inputs[ch][i]

            # Wobble via modulated delay
            _delays[ch].write(x)
            delay = 10.0 + wow
            x = _delays[ch].read_cubic(max(1.0, delay))

            # Warm filtering
            x = _lp[ch].process_sample(x)
            x = _hp[ch].process_sample(x)

            # Gentle saturation
            x = math.tanh(x * 1.5) * 0.75

            # Bit reduction (subtle)
            x = round(x * levels) / levels

            # Vinyl crackle
            if vinyl > 0:
                if random.random() < vinyl * 0.001:
                    x += (random.random() - 0.3) * vinyl * 0.3
                x += (random.random() - 0.5) * vinyl * 0.003

            outputs[ch][i] = x
