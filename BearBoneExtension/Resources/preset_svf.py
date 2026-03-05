import numpy as np
import math

# State Variable Filter parameters
CUTOFF_HZ = 1000.0  # Cutoff/center frequency in Hz
RESONANCE = 2.0      # Resonance (Q); higher = sharper peak
# Mode: "low", "high", "band", "notch"
MODE = "low"

# Persistent state per channel: [low, band]
_state = [[0.0, 0.0], [0.0, 0.0]]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Resonant State Variable Filter — multi-mode SVF (LP/HP/BP/Notch).

    Implements a digital state variable filter with selectable output mode.
    The filter computes low-pass, high-pass, and band-pass simultaneously,
    and the MODE constant selects which output is used. Resonance controls
    the sharpness of the peak at the cutoff frequency.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _state

    f = 2.0 * math.sin(math.pi * CUTOFF_HZ / sample_rate)
    q = 1.0 / RESONANCE

    for ch in range(len(inputs)):
        low = _state[ch][0] if ch < len(_state) else 0.0
        band = _state[ch][1] if ch < len(_state) else 0.0

        for i in range(frame_count):
            x = inputs[ch][i]
            low += f * band
            high = x - low - q * band
            band += f * high

            if MODE == "low":
                outputs[ch][i] = low
            elif MODE == "high":
                outputs[ch][i] = high
            elif MODE == "band":
                outputs[ch][i] = band
            else:  # notch
                outputs[ch][i] = low + high

        if ch < len(_state):
            _state[ch][0] = low
            _state[ch][1] = band
