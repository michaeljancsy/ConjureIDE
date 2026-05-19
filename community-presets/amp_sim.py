import numpy as np
import math
from conjuredsp.params import param, db, choice
from conjuredsp.filters import Biquad, BiquadCoeffs
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "channel": choice("Clean", "Crunch", "Lead", default="Crunch"),
    "gain":    db(0, 40, default=15),
    "tone":    param(0, 1, default=0.5),
    "volume":  db(-20, 6, default=0),
}

_hp = None
_mid = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Amp Sim — basic tube amplifier model.

    Models three amplifier channels: Clean (slight compression),
    Crunch (edge of breakup), and Lead (heavy saturation). Uses
    pre-EQ shaping, asymmetric soft clipping, and post-EQ tone
    control. Not a cabinet sim — pair with the cab_sim preset
    for a full amp+cab chain. Great for guitar and bass direct
    recording.

    Params:
        channel: Amp channel (Clean/Crunch/Lead)
        gain:    Preamp gain (0–40 dB)
        tone:    Post-distortion brightness (0–1)
        volume:  Master volume (-20 to +6 dB)
    """
    global _hp, _mid, _lp

    channel = int(params["channel"])
    gain = db_to_gain(params["gain"])
    tone = params["tone"]
    volume = db_to_gain(params["volume"])

    n_ch = len(inputs)

    if _hp is None:
        _hp = [Biquad() for _ in range(n_ch)]
        _mid = [Biquad() for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    # Channel-specific EQ and gain
    if channel == 0:  # Clean
        gain *= 0.3
        mid_boost = 3.0
    elif channel == 1:  # Crunch
        gain *= 1.0
        mid_boost = 5.0
    else:  # Lead
        gain *= 3.0
        mid_boost = 8.0

    lp_freq = 3000.0 + tone * 7000.0

    for ch in range(n_ch):
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(80.0, 0.7, sample_rate))
        _mid[ch].set_coeffs(BiquadCoeffs.peak(800.0, 1.5, mid_boost, sample_rate))
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            x = inputs[ch][i]

            # Input stage
            x = _hp[ch].process_sample(x)
            x = _mid[ch].process_sample(x)
            x *= gain

            # Tube-like asymmetric clipping
            if x >= 0:
                y = math.tanh(x)
            else:
                y = math.tanh(x * 1.3) * 0.8

            # Tone stack
            y = _lp[ch].process_sample(y)

            outputs[ch][i] = y * volume
