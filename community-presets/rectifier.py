import numpy as np
import math
from conjuredsp.params import param, mix, choice
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "mode":  choice("Full", "Half", default="Full"),
    "drive": param(1, 10, unit="x", default=3),
    "tone":  param(0, 1, default=0.5),
    "mix":   mix(default=0.5),
}

_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Rectifier Distortion — waveform rectification effect.

    Full-wave rectification folds negative cycles up, doubling the
    fundamental frequency and creating a buzzy octave-up effect.
    Half-wave zeros out negative cycles, producing a hollow, broken
    sound. Used in synth processing and experimental guitar tones.

    Params:
        mode:  Full or Half wave rectification
        drive: Pre-rectification gain (1–10x)
        tone:  Post-filter brightness (0–1)
        mix:   Wet/dry blend
    """
    global _lp

    mode = int(params["mode"])
    drive = params["drive"]
    tone = params["tone"]
    wet_mix = params["mix"]

    if _lp is None:
        _lp = [Biquad() for _ in range(2)]

    lp_freq = 1000.0 + tone * 15000.0

    for ch in range(len(inputs)):
        coeffs = BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate)
        _lp[ch].set_coeffs(coeffs)

        for i in range(frame_count):
            x = inputs[ch][i] * drive

            if mode == 0:  # Full-wave
                y = abs(x)
            else:  # Half-wave
                y = max(0.0, x)

            # Soft limit
            y = math.tanh(y)

            y = _lp[ch].process_sample(y)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
