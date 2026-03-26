import numpy as np
from conjuredsp.params import param

PARAMS = {
    "drive": param(1, 20, unit="x", default=5),
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
        outputs[ch][:frame_count] = np.clip(drive * inputs[ch][:frame_count], -1.0, 1.0)
