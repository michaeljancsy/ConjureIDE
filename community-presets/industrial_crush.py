import numpy as np
import math
import random
from conjuredsp.params import param, mix
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "destroy":  param(0, 1, default=0.7),
    "grind":    param(1, 20, unit="x", default=8),
    "gate":     param(0, 0.2, default=0.05),
    "mix":      mix(default=0.8),
}

_lp = None
_hp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Industrial Crush — harsh, aggressive industrial distortion.

    Combines extreme hard clipping, sample rate decimation, and
    aggressive filtering for the harsh, mechanical sound of
    industrial music. The destroy control adds digital decimation
    and bit reduction. The grind is pure gain into hard clipping.
    A noise gate cleans up the bottom end. Think Nine Inch Nails,
    Ministry, and KMFDM. Not for the faint of heart.

    Params:
        destroy: Digital destruction / decimation (0–1)
        grind:   Distortion drive (1–20x)
        gate:    Noise gate threshold (0–0.2)
        mix:     Wet/dry blend
    """
    global _lp, _hp

    destroy = params["destroy"]
    grind = params["grind"]
    gate_thresh = params["gate"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _lp is None:
        _lp = [Biquad() for _ in range(n_ch)]
        _hp = [Biquad() for _ in range(n_ch)]

    downsample = max(1, int(1 + destroy * 12))
    bits = max(2, int(16 - destroy * 10))
    levels = 2 ** bits

    for ch in range(n_ch):
        _hp[ch].set_coeffs(BiquadCoeffs.highpass(80.0, 1.0, sample_rate))
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(6000.0, 1.0, sample_rate))

        held = 0.0

        for i in range(frame_count):
            x = inputs[ch][i]

            # Gate
            if abs(x) < gate_thresh:
                x = 0.0

            # Drive
            x *= grind

            # Hard clip
            x = max(-1.0, min(1.0, x))

            # Digital destruction
            if destroy > 0:
                # Bit crush
                x = round(x * levels) / levels

                # Downsample
                if i % downsample == 0:
                    held = x
                x = held

                # Random noise
                x += (random.random() - 0.5) * destroy * 0.05

            # Shape
            x = _hp[ch].process_sample(x)
            x = _lp[ch].process_sample(x)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + x * wet_mix
