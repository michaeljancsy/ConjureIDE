import numpy as np
import math
from conjuredsp.params import param
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "tilt": param(-6, 6, unit="dB", default=0),
}

_ls = None
_hs = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tilt EQ — single-knob tonal balance.

    A single control tilts the frequency spectrum: turning right
    boosts highs while cutting lows, turning left does the opposite.
    The pivot point is around 1 kHz. Incredibly useful for quick
    tonal correction — brighten a dull recording or warm up a harsh
    one with one knob. Used in mastering for overall tonal balance
    and as a simple "tone" control on many plugins.

    Params:
        tilt: Tonal tilt (-6 dB = warm/dark, +6 dB = bright/thin)
    """
    global _ls, _hs

    tilt_db = params["tilt"]

    n_ch = len(inputs)

    if _ls is None:
        _ls = [Biquad() for _ in range(n_ch)]
        _hs = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        # Low shelf cuts, high shelf boosts (or vice versa)
        _ls[ch].set_coeffs(BiquadCoeffs.lowshelf(1000.0, 0.7, -tilt_db, sample_rate))
        _hs[ch].set_coeffs(BiquadCoeffs.highshelf(1000.0, 0.7, tilt_db, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]
            x = _ls[ch].process_sample(x)
            x = _hs[ch].process_sample(x)
            outputs[ch][i] = x
