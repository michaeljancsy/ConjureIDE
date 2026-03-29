import numpy as np
import math
import random
from conjuredsp.params import param
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "crackle":  param(0, 1, default=0.3),
    "hiss":     param(0, 0.05, default=0.005),
    "warp":     param(0, 1, default=0.2),
    "age":      param(0, 1, default=0.5),
}

_lp = None
_hp = None
_warp_phase = 0.0
_crackle_timer = 0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Vinyl Simulator — vintage record player character.

    Adds vinyl record imperfections: crackle (random pops), surface
    hiss (broadband noise), wow (slow pitch wobble from warp), and
    frequency rolloff (old record EQ). The age control darkens the
    sound and adds more artifacts. Perfect for lo-fi hip hop, chillhop,
    vaporwave, and any production aiming for vintage warmth.

    Params:
        crackle: Random pop/crackle intensity (0–1)
        hiss:    Surface noise level (0–0.05)
        warp:    Record warp / wow amount (0–1)
        age:     Overall vinyl age/degradation (0–1)
    """
    global _lp, _hp, _warp_phase, _crackle_timer

    crackle = params["crackle"]
    hiss = params["hiss"]
    warp = params["warp"]
    age = params["age"]

    n_ch = len(inputs)

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    # Age controls bandwidth
    lp_freq = 16000.0 - age * 10000.0
    hp_freq = 30.0 + age * 70.0

    two_pi = 2.0 * math.pi

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(hp_freq, 0.7, sample_rate))

    for i in range(frame_count):
        # Crackle: random pops
        pop = 0.0
        if crackle > 0:
            if random.random() < crackle * 0.002:
                pop = (random.random() - 0.3) * crackle * 0.5

        # Surface hiss
        noise = (random.random() - 0.5) * hiss * 2.0

        # Warp / wow
        wow_mod = math.sin(two_pi * _warp_phase) * warp * 0.002
        _warp_phase = (_warp_phase + 0.5 / sample_rate) % 1.0

        for ch in range(n_ch):
            x = inputs[ch][i]

            # Apply wow as slight level modulation
            x *= (1.0 + wow_mod)

            # Age filtering
            x = _lp[ch].process_sample(x)
            x = _hp[ch].process_sample(x)

            # Add artifacts
            x += pop + noise

            outputs[ch][i] = x
