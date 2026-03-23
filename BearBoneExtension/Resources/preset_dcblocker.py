import numpy as np

PARAMS = {
    "cutoff": {"min": 0.99, "max": 0.9995, "unit": "R", "default": 0.995},
}

# Persistent state per channel: [prev_x, prev_y]
_state = [[0.0, 0.0], [0.0, 0.0]]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    DC Blocker — removes DC offset from the signal.

    Implements a first-order high-pass filter:
        y[n] = x[n] - x[n-1] + R * y[n-1]
    where R controls the cutoff frequency (closer to 1.0 = lower cutoff).

    Params:
        cutoff: Filter coefficient R (0.99–0.9995, higher = lower cutoff)
    """
    global _state

    r = params["cutoff"]

    for ch in range(len(inputs)):
        prev_x = _state[ch][0] if ch < len(_state) else 0.0
        prev_y = _state[ch][1] if ch < len(_state) else 0.0

        for i in range(frame_count):
            x = inputs[ch][i]
            prev_y = x - prev_x + r * prev_y
            prev_x = x
            outputs[ch][i] = prev_y

        if ch < len(_state):
            _state[ch][0] = prev_x
            _state[ch][1] = prev_y
