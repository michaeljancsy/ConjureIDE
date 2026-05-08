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

    Params:
        gain: Volume (-24 to +12 dB)
        pan:  Stereo position (0.0 = hard left, 0.5 = center, 1.0 = hard right)
    """
    gain_db = ctx.params["gain"]
    pan = ctx.params["pan"]

    gain = db_to_gain(gain_db)
    n_ch = len(ctx.inputs)

    if n_ch == 1:
        # Mono: just apply gain
        np.multiply(ctx.inputs[0][:ctx.frame_count], gain, out=ctx.outputs[0][:ctx.frame_count])
    else:
        # Stereo: constant-power pan
        left_gain = gain * math.cos(pan * math.pi * 0.5)
        right_gain = gain * math.sin(pan * math.pi * 0.5)
        np.multiply(ctx.inputs[0][:ctx.frame_count], left_gain, out=ctx.outputs[0][:ctx.frame_count])
        np.multiply(ctx.inputs[1][:ctx.frame_count], right_gain, out=ctx.outputs[1][:ctx.frame_count])
