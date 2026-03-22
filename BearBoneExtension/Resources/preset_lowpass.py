import numpy as np
import math

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Cutoff"}

# Persistent state: previous output per channel
_prev_out = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Low-Pass Filter — simple 1-pole IIR low-pass.

    Implements y[n] = (1 - a) * x[n] + a * y[n-1].
    Rolls off at 6 dB/octave above the cutoff frequency.

    Params:
        0 (Cutoff): Cutoff frequency — 0.0 = 20 Hz, 1.0 = 20 kHz (exponential)
    """
    global _prev_out

    # Exponential mapping: 20 Hz to 20 kHz
    cutoff_hz = 20.0 * (1000.0 ** params[0])

    a = math.exp(-2.0 * math.pi * cutoff_hz / sample_rate)
    b = 1.0 - a

    for ch in range(len(inputs)):
        y = _prev_out[ch] if ch < len(_prev_out) else 0.0
        for i in range(frame_count):
            y = b * inputs[ch][i] + a * y
            outputs[ch][i] = y
        if ch < len(_prev_out):
            _prev_out[ch] = y
