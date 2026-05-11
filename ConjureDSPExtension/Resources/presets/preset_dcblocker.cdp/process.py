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

    r = math.exp(-2.0 * math.pi * ctx.params["cutoff"] / ctx.sample_rate)
    n_ch, frame_count = ctx.inputs.shape

    # IIR feedback is sequential per channel (y[n] depends on y[n-1]), so
    # the inner loop stays per-sample. The outer per-channel loop stays for
    # the same reason. Slack-region slicing is no longer needed.
    for ch in range(n_ch):
        prev_x = _state[ch][0] if ch < len(_state) else 0.0
        prev_y = _state[ch][1] if ch < len(_state) else 0.0
        row_in = ctx.inputs[ch]
        row_out = ctx.outputs[ch]
        for i in range(frame_count):
            x = row_in[i]
            prev_y = x - prev_x + r * prev_y
            prev_x = x
            row_out[i] = prev_y

        if ch < len(_state):
            _state[ch][0] = prev_x
            _state[ch][1] = prev_y
