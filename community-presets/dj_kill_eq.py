import numpy as np
import math
from conjuredsp.params import db, toggle
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "low":      db(-60, 6, default=0),
    "mid":      db(-60, 6, default=0),
    "high":     db(-60, 6, default=0),
    "kill_low": toggle(),
    "kill_mid": toggle(),
    "kill_high": toggle(),
}

_lp = None
_hp = None
_bp_lp = None
_bp_hp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    DJ Kill EQ — 3-band isolator with kill switches.

    A DJ-style EQ with independent low/mid/high gain controls and
    kill switches that completely silence each band. The kill switches
    provide the dramatic band drops used in DJ sets — kill the bass
    for a breakdown, kill the mids for a filter sweep feel, or
    isolate just the highs for tension. Standard gear on every
    DJ mixer.

    Params:
        low:       Bass gain (-60 to +6 dB)
        mid:       Mid gain (-60 to +6 dB)
        high:      Treble gain (-60 to +6 dB)
        kill_low:  Kill bass band
        kill_mid:  Kill mid band
        kill_high: Kill treble band
    """
    global _lp, _hp, _bp_lp, _bp_hp

    from conjuredsp.dsp import db_to_gain

    low_gain = 0.0 if params["kill_low"] > 0.5 else db_to_gain(params["low"])
    mid_gain = 0.0 if params["kill_mid"] > 0.5 else db_to_gain(params["mid"])
    high_gain = 0.0 if params["kill_high"] > 0.5 else db_to_gain(params["high"])

    n_ch = len(inputs)

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]
        _bp_lp = [Biquad() for _ in range(n_ch)]
        _bp_hp = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(250.0, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(2500.0, 0.7, sample_rate))
        _bp_lp[ch].set_coeffs(BiquadCoeffs.lowpass(2500.0, 0.7, sample_rate))
        _bp_hp[ch].set_coeffs(BiquadCoeffs.highpass(250.0, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]

            low = _lp[ch].process_sample(x) * low_gain
            high = _hp[ch].process_sample(x) * high_gain
            mid_sig = _bp_hp[ch].process_sample(x)
            mid = _bp_lp[ch].process_sample(mid_sig) * mid_gain

            outputs[ch][i] = low + mid + high
