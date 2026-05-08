import math
from conjuredsp.params import freq

PARAMS = {
    "cutoff": freq(min=4, max=70, default=4),
}

# Persistent state per channel: [prev_x, prev_y]
_state = [[0.0, 0.0], [0.0, 0.0]]


def process(ctx):
    """
    DC Blocker — removes DC offset from the signal.

    Implements a first-order high-pass filter:
        y[n] = x[n] - x[n-1] + R * y[n-1]
    where R controls the cutoff frequency (closer to 1.0 = lower cutoff).
    The cutoff parameter sets the -3dB frequency in Hz; R is computed
    from the sample rate.

    Params:
        cutoff: High-pass cutoff frequency (4–70 Hz)
    """
    global _state

    cutoff_hz = ctx.params["cutoff"]
    r = math.exp(-2.0 * math.pi * cutoff_hz / ctx.sample_rate)

    for ch in range(len(ctx.inputs)):
        prev_x = _state[ch][0] if ch < len(_state) else 0.0
        prev_y = _state[ch][1] if ch < len(_state) else 0.0

        for i in range(ctx.frame_count):
            x = ctx.inputs[ch][i]
            prev_y = x - prev_x + r * prev_y
            prev_x = x
            ctx.outputs[ch][i] = prev_y

        if ch < len(_state):
            _state[ch][0] = prev_x
            _state[ch][1] = prev_y
