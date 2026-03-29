import numpy as np
import math
from conjuredsp.params import freq, db, param
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "frequency": freq(min=3000, max=10000, default=6000),
    "threshold": db(-30, 0, default=-15),
    "range":     db(-20, 0, default=-10),
    "listen":    param(0, 1, default=0),
}

_bp = None
_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    De-Esser — frequency-selective sibilance reducer.

    Detects sibilant frequencies (harsh "s" and "t" sounds) and
    dynamically reduces them. Unlike the factory de-esser, this
    version has adjustable frequency targeting and a range control
    to limit maximum reduction. The listen parameter lets you
    audition just the sibilant band to dial in the frequency.
    Essential for vocal mixing, podcast production, and dialogue.

    Params:
        frequency: Sibilance detection frequency (3–10 kHz)
        threshold: Level above which de-essing engages (-30 to 0 dB)
        range:     Maximum sibilance reduction (-20 to 0 dB)
        listen:    Monitor the sibilant band only (0 = normal, 1 = listen)
    """
    global _bp, _envelope

    center = params["frequency"]
    thresh = db_to_gain(params["threshold"])
    max_reduction = db_to_gain(params["range"])
    listen = params["listen"]

    n_ch = len(inputs)

    if _bp is None:
        _bp = [Biquad() for _ in range(n_ch)]

    att = smooth_coeff(0.5, sample_rate)
    rel = smooth_coeff(10.0, sample_rate)

    for ch in range(n_ch):
        _bp[ch].set_coeffs(BiquadCoeffs.bandpass(center, 3.0, sample_rate))

    for i in range(frame_count):
        # Detect sibilant energy
        sib_energy = 0.0
        for ch in range(n_ch):
            sib = _bp[ch].process_sample(inputs[ch][i])
            sib_energy = max(sib_energy, abs(sib))

        # Envelope follower
        if sib_energy > _envelope:
            _envelope = att * _envelope + (1.0 - att) * sib_energy
        else:
            _envelope = rel * _envelope + (1.0 - rel) * sib_energy

        # Gain reduction when sibilance exceeds threshold
        if _envelope > thresh:
            overshoot = _envelope / thresh
            gain = 1.0 / overshoot
            gain = max(gain, max_reduction)
        else:
            gain = 1.0

        for ch in range(n_ch):
            if listen > 0.5:
                # Listen mode: hear only the sibilant band
                outputs[ch][i] = _bp[ch].process_sample(inputs[ch][i]) * 3.0
            else:
                # Apply gain reduction to sibilant frequencies only
                sib = _bp[ch].process_sample(inputs[ch][i])
                outputs[ch][i] = inputs[ch][i] - sib * (1.0 - gain)
