import numpy as np
from conjuredsp.params import param

PARAMS = {
    "drive": param(1, 20, unit="x", default=5),
}


def process(ctx):
    """
    Hard Clip — hard clipping distortion.

    Amplifies the signal by the drive amount, then clips any values
    exceeding +/-1.0. Produces a harsh, buzzy distortion with odd harmonics.
    Higher drive values push more of the signal into clipping.

    Controls:
        drive: Pre-clip gain (1–20x)
    """
    drive = ctx.params["drive"]
    # Whole-array clip across all channels in one call.
    np.clip(drive * ctx.inputs, -1.0, 1.0, out=ctx.outputs)
