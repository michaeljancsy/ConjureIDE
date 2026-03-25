import numpy as np
import math

PARAMS = {
    "cutoff":    {"min": 20.0, "max": 20000.0, "unit": "Hz", "default": 1000.0, "curve": "log"},
    "resonance": {"min": 0.5,  "max": 10.0,    "unit": "Q",  "default": 1.0},
}

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

    Params:
        cutoff:    Cutoff frequency (20–20000 Hz)
        resonance: Resonance Q (0.5–10)
    """
    global _state

    cutoff_hz = params["cutoff"]
    resonance = params["resonance"]

    f = 2.0 * math.sin(math.pi * cutoff_hz / sample_rate)
    q = 1.0 / resonance

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
