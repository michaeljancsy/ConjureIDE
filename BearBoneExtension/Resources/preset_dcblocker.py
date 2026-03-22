import numpy as np

# Parameters:
CUTOFF = 0

# Persistent state per channel: [prev_x, prev_y]
_state = [[0.0, 0.0], [0.0, 0.0]]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    DC Blocker — removes DC offset from the signal.

    Implements a first-order high-pass filter:
        y[n] = x[n] - x[n-1] + R * y[n-1]
    where R controls the cutoff frequency (closer to 1.0 = lower cutoff).

    Params:
        0 (Cutoff): Higher values = higher cutoff frequency.
                    0.0 = R=0.9995 (~1 Hz), 1.0 = R=0.99 (~160 Hz)
    """
    global _state

    # Inverted: higher param = higher cutoff = lower R
    r = 0.9995 - params[CUTOFF] * 0.0095  # 0.9995 to 0.99

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
