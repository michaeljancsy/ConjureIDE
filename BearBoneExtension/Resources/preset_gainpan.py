import numpy as np
import math

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Gain", 1: "Pan"}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Gain + Pan — volume control with stereo panning.

    Applies gain and constant-power panning to the signal.

    Params:
        0 (Gain): Volume — 0.0 = -24 dB, 0.5 = 0 dB, 1.0 = +12 dB
        1 (Pan):  Stereo position — 0.0 = hard left, 0.5 = center, 1.0 = hard right
    """
    gain_db = -24.0 + params[0] * 36.0   # -24 dB to +12 dB
    pan = params[1]                        # 0.0 (left) to 1.0 (right)

    gain = 10.0 ** (gain_db / 20.0)
    n_ch = len(inputs)

    if n_ch == 1:
        # Mono: just apply gain
        outputs[0][:frame_count] = inputs[0][:frame_count] * gain
    else:
        # Stereo: constant-power pan
        left_gain = gain * math.cos(pan * math.pi * 0.5)
        right_gain = gain * math.sin(pan * math.pi * 0.5)
        outputs[0][:frame_count] = inputs[0][:frame_count] * left_gain
        outputs[1][:frame_count] = inputs[1][:frame_count] * right_gain
