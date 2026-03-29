import numpy as np
import math
from conjuredsp.params import param, db, mix

PARAMS = {
    "drive":  param(1, 10, unit="x", default=2),
    "tone":   param(0, 1, default=0.5),
    "mix":    mix(default=0.7),
}

# One-pole filter state
_lp_state = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Tube Warmth — gentle tube-style saturation.

    Models the soft compression and even-harmonic generation of a vacuum
    tube amplifier. A post-saturation tone control rolls off harsh highs.
    Great for adding analog warmth to digital recordings, synths, or drums.

    Params:
        drive: Saturation intensity (1–10x)
        tone:  Brightness (0 = dark, 1 = bright)
        mix:   Wet/dry blend
    """
    global _lp_state

    drive = params["drive"]
    tone = params["tone"]
    wet_mix = params["mix"]

    # Tone control: one-pole lowpass, cutoff from 800 Hz to 16 kHz
    cutoff = 800.0 + tone * 15200.0
    rc = 1.0 / (2.0 * math.pi * cutoff)
    dt = 1.0 / sample_rate
    alpha = dt / (rc + dt)

    for ch in range(len(inputs)):
        lp = _lp_state[ch] if ch < len(_lp_state) else 0.0

        for i in range(frame_count):
            x = inputs[ch][i] * drive

            # Asymmetric soft clipping — more even harmonics
            if x >= 0:
                y = math.tanh(x)
            else:
                y = math.tanh(x * 0.8) * 1.25

            # Tone filter
            lp += alpha * (y - lp)

            # Mix
            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + lp * wet_mix

        if ch < len(_lp_state):
            _lp_state[ch] = lp
