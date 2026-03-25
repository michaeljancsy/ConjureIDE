import numpy as np

PARAMS = {
    "drive": {"min": 1.0, "max": 20.0, "unit": "x", "default": 5.0},
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Hard Clip — hard clipping distortion.

    Amplifies the signal by the drive amount, then clips any values
    exceeding +/-1.0. Produces a harsh, buzzy distortion with odd harmonics.
    Higher drive values push more of the signal into clipping.

    Params:
        drive: Pre-clip gain (1–20x)
    """
    drive = params["drive"]

    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], drive, out=outputs[ch][:frame_count])
        np.clip(outputs[ch][:frame_count], -1.0, 1.0, out=outputs[ch][:frame_count])
