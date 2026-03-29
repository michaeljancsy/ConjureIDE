import numpy as np
import math
from conjuredsp.params import param, freq, mix

PARAMS = {
    "fuzz":   param(1, 50, unit="x", default=15),
    "tone":   freq(min=500, max=8000, default=2000),
    "gate":   param(0, 0.1, default=0.01),
    "level":  param(0, 1, default=0.7),
}

# Filter state
_lp = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Fuzz — classic 60s germanium fuzz pedal.

    Inspired by the Fuzz Face circuit: heavy clipping with a sputtery,
    gated character at low input levels. The tone knob is a simple lowpass
    to tame the buzzy top end. Perfect for psychedelic guitar leads,
    bass fuzz, or destroying synths.

    Params:
        fuzz:  Fuzz intensity (1–50x gain into clipping)
        tone:  Tone filter cutoff (500–8000 Hz)
        gate:  Noise gate threshold (0–0.1)
        level: Output level (0–1)
    """
    global _lp

    fuzz = params["fuzz"]
    tone_hz = params["tone"]
    gate_thresh = params["gate"]
    level = params["level"]

    rc = 1.0 / (2.0 * math.pi * tone_hz)
    dt = 1.0 / sample_rate
    alpha = dt / (rc + dt)

    for ch in range(len(inputs)):
        lp = _lp[ch] if ch < len(_lp) else 0.0

        for i in range(frame_count):
            x = inputs[ch][i]

            # Gate — fuzz faces have a sputtery gate character
            if abs(x) < gate_thresh:
                x = 0.0

            # Heavy asymmetric clipping
            x *= fuzz
            if x > 0:
                y = 1.0 - math.exp(-x)
            else:
                y = -(1.0 - math.exp(x * 1.5))

            # Tone filter
            lp += alpha * (y - lp)

            outputs[ch][i] = lp * level

        if ch < len(_lp):
            _lp[ch] = lp
