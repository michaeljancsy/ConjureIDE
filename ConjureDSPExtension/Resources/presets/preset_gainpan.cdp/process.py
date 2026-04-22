import numpy as np
import math
from conjuredsp.params import db, param
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "gain": db(-24, 12, default=0),
    "pan":  param(0, 1, default=0.5),
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Gain + Pan — volume control with stereo panning.

    Applies gain and constant-power panning to the signal.

    Params:
        gain: Volume (-24 to +12 dB)
        pan:  Stereo position (0.0 = hard left, 0.5 = center, 1.0 = hard right)
    """
    gain_db = params["gain"]
    pan = params["pan"]

    gain = db_to_gain(gain_db)
    n_ch = len(inputs)

    if n_ch == 1:
        # Mono: just apply gain
        np.multiply(inputs[0][:frame_count], gain, out=outputs[0][:frame_count])
    else:
        # Stereo: constant-power pan
        left_gain = gain * math.cos(pan * math.pi * 0.5)
        right_gain = gain * math.sin(pan * math.pi * 0.5)
        np.multiply(inputs[0][:frame_count], left_gain, out=outputs[0][:frame_count])
        np.multiply(inputs[1][:frame_count], right_gain, out=outputs[1][:frame_count])
