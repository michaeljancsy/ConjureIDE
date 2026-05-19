import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "quality": param(0, 1, default=0.5),
    "noise":   param(0, 0.05, default=0.01),
    "mix":     mix(default=1.0),
}

_rng_state = 12345

def _rng():
    global _rng_state
    _rng_state = (_rng_state * 1664525 + 1013904223) & 0xFFFFFFFF
    return _rng_state / 4294967296.0

_hp = None
_lp = None
_mid = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Telephone — lo-fi telephone / radio bandpass effect.

    Simulates the narrow bandwidth of a telephone line (300 Hz to
    3.4 kHz) with mid-frequency boost and added noise. The quality
    control goes from a pristine phone call to a barely intelligible
    walkie-talkie. Great for vocal effects, lo-fi transitions, and
    recreating the "voice on the phone" production trick used in
    countless songs and films.

    Params:
        quality: Phone line quality (0 = terrible, 1 = decent)
        noise:   Line noise / crackle (0–0.05)
        mix:     Wet/dry blend
    """
    global _hp, _lp, _mid

    quality = params["quality"]
    noise_level = params["noise"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _hp is None:
        _hp = [Biquad() for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]
        _mid = [Biquad() for _ in range(n_ch)]

    # Bandwidth narrows with lower quality
    hp_freq = 300.0 + (1.0 - quality) * 700.0
    lp_freq = 3400.0 - (1.0 - quality) * 1800.0

    for ch in range(n_ch):
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(hp_freq, 1.0, sample_rate))
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 1.0, sample_rate))
        _mid[ch].set_coeffs(BiquadCoeffs.peak(1500.0, 1.0, 6.0, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]

            # Bandpass telephone spectrum
            y = _hp[ch].process_sample(x)
            y = _lp[ch].process_sample(y)
            y = _mid[ch].process_sample(y)

            # Soft clip (phone line compression)
            y = math.tanh(y * 2.0) * 0.6

            # Line noise
            y += (_rng() - 0.5) * noise_level

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
