import numpy as np
from conjuredsp.params import db, freq
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "proximity": db(0, 12, default=6),
    "frequency": freq(min=80, max=300, default=150),
    "warmth":    db(0, 6, default=2),
}

_ls = None
_peak = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Proximity Bass — bass proximity effect enhancement.

    Simulates the bass boost that occurs when a microphone is placed
    very close to a sound source (the proximity effect). A low shelf
    adds warmth and weight, while a gentle peak in the low-mids
    adds body. Use on vocals for intimate, close-mic warmth; on
    bass guitar for weight; or on kick drums for thump. The opposite
    of a high-pass: intentional bass enhancement.

    Params:
        proximity: Bass boost amount (0–12 dB)
        frequency: Center frequency of the enhancement (80–300 Hz)
        warmth:    Low-mid body boost (0–6 dB)
    """
    global _ls, _peak

    proximity_db = params["proximity"]
    freq_hz = params["frequency"]
    warmth_db = params["warmth"]

    n_ch = len(inputs)

    if _ls is None:
        _ls = [Biquad() for _ in range(n_ch)]
        _peak = [Biquad() for _ in range(n_ch)]

    for ch in range(n_ch):
        _ls[ch].set_coeffs(BiquadCoeffs.lowshelf(freq_hz, 0.7, proximity_db, sample_rate))
        _peak[ch].set_coeffs(BiquadCoeffs.peak(freq_hz * 2.0, 1.0, warmth_db, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]
            x = _ls[ch].process_sample(x)
            x = _peak[ch].process_sample(x)
            outputs[ch][i] = x
