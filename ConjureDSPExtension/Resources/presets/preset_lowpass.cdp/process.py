import math
from conjuredsp import freq

PARAMS = {
    "cutoff": freq(),
}

# Persistent state: previous output per channel
_prev_out = [0.0, 0.0]


def process(ctx):
    """
    Low-Pass Filter — simple 1-pole IIR low-pass.

    Implements y[n] = (1 - a) * x[n] + a * y[n-1].
    Rolls off at 6 dB/octave above the cutoff frequency.

    Params:
        cutoff: Cutoff frequency (20–20000 Hz)
    """
    global _prev_out

    cutoff_hz = ctx.params["cutoff"]

    a = math.exp(-2.0 * math.pi * cutoff_hz / ctx.sample_rate)
    b = 1.0 - a

    n_ch, frame_count = ctx.inputs.shape

    for ch in range(n_ch):
        y = _prev_out[ch] if ch < len(_prev_out) else 0.0
        row_in = ctx.inputs[ch]
        row_out = ctx.outputs[ch]
        for i in range(frame_count):
            y = b * row_in[i] + a * y
            row_out[i] = y
        if ch < len(_prev_out):
            _prev_out[ch] = y
