import numpy as np
import math
from conjuredsp.params import param, choice, mix

PARAMS = {
    "type":   choice("Even", "Odd", "Both", default="Even"),
    "amount": param(0, 1, default=0.5),
    "mix":    mix(default=0.5),
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Harmonics Boost — selective harmonic enhancement.

    Generates even harmonics (warm, tube-like), odd harmonics
    (aggressive, hollow), or both. Even harmonics add warmth and
    body (like a tube amp). Odd harmonics add edge and presence
    (like a transistor amp). The amount control drives the
    saturation harder for more harmonic content. A precise
    alternative to generic distortion when you know exactly
    what character you want.

    Params:
        type:   Which harmonics to generate (Even/Odd/Both)
        amount: Harmonic generation intensity (0–1)
        mix:    Wet/dry blend
    """
    harm_type = int(params["type"])
    amount = params["amount"]
    wet_mix = params["mix"]

    drive = 1.0 + amount * 8.0

    for ch in range(len(inputs)):
        for i in range(frame_count):
            x = inputs[ch][i]
            xd = x * drive

            if harm_type == 0:  # Even harmonics
                # Asymmetric function generates even harmonics
                y = math.tanh(xd) + 0.3 * (math.tanh(xd) ** 2) * (1.0 if xd >= 0 else -1.0)
                # Subtract fundamental to isolate harmonics
                harmonics = y - x
            elif harm_type == 1:  # Odd harmonics
                # Symmetric function generates odd harmonics
                y = math.tanh(xd)
                harmonics = y - x
            else:  # Both
                # Full saturation
                y = math.tanh(xd * 1.5) * 0.7
                harmonics = y - x

            outputs[ch][i] = x + harmonics * wet_mix
