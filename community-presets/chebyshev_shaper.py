import numpy as np
import math
from conjuredsp.params import param, choice, mix

PARAMS = {
    "harmonic": choice("2nd", "3rd", "4th", "5th", default="2nd"),
    "drive":    param(0, 1, default=0.5),
    "mix":      mix(default=0.5),
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Chebyshev Waveshaper — harmonic-specific distortion.

    Uses Chebyshev polynomials to generate specific harmonic overtones.
    Unlike general distortion, each polynomial adds exactly one harmonic:
    2nd = octave up (warm), 3rd = octave + fifth (hollow), 4th = two
    octaves (bright), 5th = complex (buzzy). Precise tonal control
    for sound design and subtle harmonic enhancement.

    Params:
        harmonic: Which harmonic to emphasize (2nd–5th)
        drive:    Polynomial blend intensity (0–1)
        mix:      Wet/dry blend
    """
    harm_idx = int(params["harmonic"])
    drive = params["drive"]
    wet_mix = params["mix"]

    for ch in range(len(inputs)):
        for i in range(frame_count):
            x = inputs[ch][i]

            # Clamp input to [-1, 1] for Chebyshev validity
            xc = max(-1.0, min(1.0, x))

            # Chebyshev polynomials T_n(x)
            if harm_idx == 0:    # T2: 2x^2 - 1
                shaped = 2.0 * xc * xc - 1.0
            elif harm_idx == 1:  # T3: 4x^3 - 3x
                shaped = 4.0 * xc * xc * xc - 3.0 * xc
            elif harm_idx == 2:  # T4: 8x^4 - 8x^2 + 1
                x2 = xc * xc
                shaped = 8.0 * x2 * x2 - 8.0 * x2 + 1.0
            else:                # T5: 16x^5 - 20x^3 + 5x
                x2 = xc * xc
                x3 = x2 * xc
                shaped = 16.0 * x2 * x3 - 20.0 * x3 + 5.0 * xc

            # Blend shaped signal with original
            y = x + drive * (shaped - x)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
