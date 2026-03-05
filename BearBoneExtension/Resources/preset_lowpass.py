import numpy as np
import math

# Low-pass filter parameters
CUTOFF_HZ = 800.0  # Cutoff frequency in Hz

# Persistent state: previous output per channel
_prev_out = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Low-Pass Filter — simple 1-pole IIR low-pass.

    Implements the simplest possible IIR low-pass filter:
        y[n] = (1 - a) * x[n] + a * y[n-1]
    where a = exp(-2 * pi * cutoff / sample_rate).
    Rolls off at 6 dB/octave above the cutoff frequency.
    State is maintained per channel across callbacks.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _prev_out

    a = math.exp(-2.0 * math.pi * CUTOFF_HZ / sample_rate)
    b = 1.0 - a

    for ch in range(len(inputs)):
        y = _prev_out[ch] if ch < len(_prev_out) else 0.0
        for i in range(frame_count):
            y = b * inputs[ch][i] + a * y
            outputs[ch][i] = y
        if ch < len(_prev_out):
            _prev_out[ch] = y
