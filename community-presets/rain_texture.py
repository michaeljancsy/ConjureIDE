import numpy as np
import math
import random
from conjuredsp.params import param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "density":  param(0, 1, default=0.5),
    "size":     param(0, 1, default=0.5),
    "damping":  param(0, 1, default=0.4),
    "mix":      mix(default=0.3),
}

_hp = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Rain Texture — rain-like noise overlay.

    Adds filtered noise that sounds like rain, from light drizzle
    to heavy downpour. The density controls how many "drops" occur,
    the size controls whether it sounds like fine mist or heavy
    drops. The noise is shaped with bandpass filtering to sound
    natural. Layer over any music for lo-fi ambience, ASMR, or
    cozy atmosphere.

    Params:
        density: Raindrop density (0 = light drizzle, 1 = downpour)
        size:    Drop size (0 = fine mist, 1 = heavy drops)
        damping: High-frequency rolloff (0 = crispy, 1 = muffled/indoor)
        mix:     Rain noise level blend
    """
    global _hp, _lp

    density = params["density"]
    size = params["size"]
    damping = params["damping"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _hp is None:
        _hp = [Biquad() for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    hp_freq = 200.0 + (1.0 - size) * 2000.0
    lp_freq = 12000.0 - damping * 8000.0

    for ch in range(n_ch):
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(hp_freq, 0.7, sample_rate))
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

    for i in range(frame_count):
        # Generate rain noise: white noise with random "drops"
        base_noise = (random.random() - 0.5) * density * 0.3

        # Add occasional larger drops
        if random.random() < density * 0.01:
            base_noise += (random.random() - 0.5) * size * 0.5

        for ch in range(n_ch):
            # Slightly different noise per channel for stereo
            noise = base_noise + (random.random() - 0.5) * density * 0.05

            # Shape the rain noise
            noise = _hp[ch].process_sample(noise)
            noise = _lp[ch].process_sample(noise)

            outputs[ch][i] = inputs[ch][i] + noise * wet_mix
