import numpy as np
import math
from conjuredsp.params import choice, param
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "cabinet":   choice("1x12", "2x12", "4x12", "Bass 4x10", default="4x12"),
    "mic":       param(0, 1, default=0.5),
    "resonance": param(0, 1, default=0.4),
}

_lp1 = None
_lp2 = None
_hp = None
_peak = None
_notch = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Cabinet Sim — speaker cabinet simulation.

    Models the frequency response of common guitar and bass cabinets
    using a chain of EQ filters. Real speakers have a sharp rolloff
    above 5-6 kHz, a resonant peak around 2-4 kHz, and limited bass
    response. The mic control simulates positioning from center cone
    (bright, harsh) to edge/off-axis (dark, smooth). Pair with
    amp_sim for a complete recording chain.

    Params:
        cabinet:   Cabinet type (1x12, 2x12, 4x12, Bass 4x10)
        mic:       Mic position (0 = center/bright, 1 = edge/dark)
        resonance: Speaker cone resonance amount (0–1)
    """
    global _lp1, _lp2, _hp, _peak, _notch

    cab_type = int(params["cabinet"])
    mic = params["mic"]
    resonance = params["resonance"]

    n_ch = len(inputs)

    if _lp1 is None:
        _lp1 = [Biquad() for _ in range(n_ch)]
        _lp2 = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]
        _peak = [Biquad() for _ in range(n_ch)]
        _notch = [Biquad() for _ in range(n_ch)]

    # Cabinet characteristics
    if cab_type == 0:  # 1x12 — open back, bright
        lp_freq = 5500.0
        hp_freq = 100.0
        peak_freq = 3000.0
        peak_gain = 3.0 + resonance * 4.0
    elif cab_type == 1:  # 2x12 — balanced
        lp_freq = 5000.0
        hp_freq = 80.0
        peak_freq = 2500.0
        peak_gain = 4.0 + resonance * 4.0
    elif cab_type == 2:  # 4x12 — closed back, thick
        lp_freq = 4500.0
        hp_freq = 70.0
        peak_freq = 2000.0
        peak_gain = 5.0 + resonance * 4.0
    else:  # Bass 4x10
        lp_freq = 4000.0
        hp_freq = 40.0
        peak_freq = 800.0
        peak_gain = 3.0 + resonance * 4.0

    # Mic position affects upper rolloff
    lp_freq -= mic * 2000.0

    for ch in range(n_ch):
        _lp1[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.8, sample_rate))
        _lp2[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq * 1.5, 0.7, sample_rate))
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(hp_freq, 0.7, sample_rate))
        _peak[ch].set_coeffs(BiquadCoeffs.peak(peak_freq, 1.5, peak_gain, sample_rate))
        _notch[ch].set_coeffs(BiquadCoeffs.notch(4500.0, 2.0, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]
            x = _hp[ch].process_sample(x)
            x = _lp1[ch].process_sample(x)
            x = _lp2[ch].process_sample(x)
            x = _peak[ch].process_sample(x)
            x = _notch[ch].process_sample(x)
            outputs[ch][i] = x
