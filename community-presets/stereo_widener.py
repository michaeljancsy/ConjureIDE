import numpy as np
import math
from conjuredsp.params import param, freq
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "width":     param(0, 2, default=1.5),
    "bass_mono": freq(min=50, max=500, default=200),
    "bass_width": param(0, 1, default=0),
}

_lp_l = None
_lp_r = None
_hp_l = None
_hp_r = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Stereo Widener — frequency-dependent stereo width control.

    Controls stereo width with a single knob: below 1.0 narrows
    toward mono, above 1.0 widens beyond natural stereo. The
    bass_mono control forces low frequencies to mono (essential for
    vinyl mastering and preventing bass cancellation in PA systems)
    while keeping mids and highs wide. A mastering essential.

    Params:
        width:      Overall width (0 = mono, 1 = unchanged, 2 = extra wide)
        bass_mono:  Frequency below which to mono-ize (50–500 Hz)
        bass_width: Width of the bass region (0 = full mono, 1 = unchanged)
    """
    global _lp_l, _lp_r, _hp_l, _hp_r

    width = params["width"]
    mono_freq = params["bass_mono"]
    bass_w = params["bass_width"]

    n_ch = len(inputs)

    if n_ch < 2:
        outputs[0][:frame_count] = inputs[0][:frame_count]
        return

    if _lp_l is None:
        _lp_l = Biquad()
        _lp_r = Biquad()
        _hp_l = Biquad()
        _hp_r = Biquad()

    _lp_l.set_coeffs(BiquadCoeffs.lowpass(mono_freq, 0.7, sample_rate))
    _lp_r.set_coeffs(BiquadCoeffs.lowpass(mono_freq, 0.7, sample_rate))
    _hp_l.set_coeffs(BiquadCoeffs.highpass(mono_freq, 0.7, sample_rate))
    _hp_r.set_coeffs(BiquadCoeffs.highpass(mono_freq, 0.7, sample_rate))

    for i in range(frame_count):
        left = inputs[0][i]
        right = inputs[1][i]

        # Split into low and high
        lo_l = _lp_l.process_sample(left)
        lo_r = _lp_r.process_sample(right)
        hi_l = _hp_l.process_sample(left)
        hi_r = _hp_r.process_sample(right)

        # Bass mono/width control
        lo_mid = (lo_l + lo_r) * 0.5
        lo_side = (lo_l - lo_r) * 0.5
        lo_l_out = lo_mid + lo_side * bass_w
        lo_r_out = lo_mid - lo_side * bass_w

        # High frequency width control
        hi_mid = (hi_l + hi_r) * 0.5
        hi_side = (hi_l - hi_r) * 0.5
        hi_l_out = hi_mid + hi_side * width
        hi_r_out = hi_mid - hi_side * width

        outputs[0][i] = lo_l_out + hi_l_out
        outputs[1][i] = lo_r_out + hi_r_out
