import numpy as np
import math
from conjuredsp.params import db, param
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "gain": db(-24, 12, default=0),
    "pan":  param(0, 1, default=0.5),
}


def process(ctx):
    """
    Gain + Pan — volume control with stereo panning.

    Applies gain and constant-power panning to the signal.

    Controls:
        gain: Volume (-24 to +12 dB)
        pan:  Stereo position (0.0 = hard left, 0.5 = center, 1.0 = hard right)
    """
    gain = db_to_gain(ctx.params["gain"])
    pan = ctx.params["pan"]

    if ctx.inputs.shape[0] == 1:
        # Mono: just apply gain.
        np.multiply(ctx.inputs, gain, out=ctx.outputs)
    else:
        # Stereo: constant-power pan. Build a (channels, 1) gain vector so
        # numpy broadcasts it across the frame_count axis in one call.
        gains = np.array(
            [[gain * math.cos(pan * math.pi * 0.5)],
             [gain * math.sin(pan * math.pi * 0.5)]],
            dtype=np.float32,
        )
        np.multiply(ctx.inputs, gains, out=ctx.outputs)
