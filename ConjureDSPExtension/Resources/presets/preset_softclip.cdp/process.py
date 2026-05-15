import numpy as np
from conjuredsp.params import param

PARAMS = {
    "drive": param(1, 15, unit="x", default=3),
}


def process(ctx):
    """
    Soft Clip — tanh waveshaping saturation.

    Applies a smooth, warm saturation by passing the signal through a
    hyperbolic tangent function. The drive parameter controls how hard
    the signal is pushed into the nonlinearity. Output is normalized
    so that low-level signals pass through at unity gain.

    Controls:
        drive: Saturation amount (1–15x)
    """
    drive = ctx.params["drive"]
    norm = 1.0 / np.tanh(drive)
    # np.tanh broadcasts across channels; out= writes straight into the
    # backing array. Single ufunc call covers the whole block.
    np.tanh(drive * ctx.inputs, out=ctx.outputs)
    ctx.outputs *= norm
