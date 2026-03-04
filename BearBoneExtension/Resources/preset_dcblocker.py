import numpy as np

# DC Blocker parameters
R = 0.995  # Pole radius (higher = lower cutoff, slower response)

# Persistent state per channel: [prev_x, prev_y]
_state = [[0.0, 0.0], [0.0, 0.0]]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    DC Blocker — removes DC offset from the signal.

    Implements a first-order high-pass filter:
        y[n] = x[n] - x[n-1] + R * y[n-1]
    where R controls the cutoff frequency (closer to 1.0 = lower cutoff).
    At R=0.995 the -3dB point is around 16 Hz at 44.1 kHz, effectively
    removing any DC offset while leaving audio content untouched.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    global _state

    for ch in range(len(inputs)):
        prev_x = _state[ch][0] if ch < len(_state) else 0.0
        prev_y = _state[ch][1] if ch < len(_state) else 0.0

        for i in range(frame_count):
            x = inputs[ch][i]
            prev_y = x - prev_x + R * prev_y
            prev_x = x
            outputs[ch][i] = prev_y

        if ch < len(_state):
            _state[ch][0] = prev_x
            _state[ch][1] = prev_y
