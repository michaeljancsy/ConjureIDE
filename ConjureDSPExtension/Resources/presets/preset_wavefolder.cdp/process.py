import numpy as np
from conjuredsp.params import param

PARAMS = {
    "drive": param(1, 20, unit="x", default=5),
}


def process(ctx):
    """
    Wavefolder — folds the waveform back when it exceeds +/-1.

    Applies gain (drive) to the input, then uses triangle-wave wrapping
    to fold the signal back into the +/-1 range. Each fold reflects the
    waveform, producing increasingly rich harmonic content as drive increases.
    Unlike clipping, wavefolding preserves energy and creates a distinctive
    metallic/buzzy timbre popular in modular synthesis.

    Controls:
        drive: Fold intensity (1–20x)
    """
    drive = ctx.params["drive"]

    n_ch = ctx.inputs.shape[0]
    for ch in range(n_ch):
        x = ctx.outputs[ch]
        np.multiply(ctx.inputs[ch], drive, out=x)
        # Triangle-wave fold: maps any value into [-1, 1]
        t = (x + 1.0) * 0.25
        t = t - np.floor(t)
        ctx.outputs[ch] = 1.0 - np.abs(t * 4.0 - 2.0)
