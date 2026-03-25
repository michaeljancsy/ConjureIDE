import numpy as np
import math

PARAMS = {
    "gain": {"min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0},
    "pan":  {"min": 0.0,   "max": 1.0,  "unit": "",   "default": 0.5},
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

    gain = 10.0 ** (gain_db / 20.0)
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
