import numpy as np

PARAMS = {
    "drive": {"min": 1.0, "max": 15.0, "unit": "x", "default": 3.0},
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Soft Clip — tanh waveshaping saturation.

    Applies a smooth, warm saturation by passing the signal through a
    hyperbolic tangent function. The drive parameter controls how hard
    the signal is pushed into the nonlinearity. Output is normalized
    so that low-level signals pass through at unity gain.

    Params:
        drive: Saturation amount (1–15x)
    """
    drive = params["drive"]
    norm = 1.0 / np.tanh(drive)

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = np.tanh(drive * inputs[ch][:frame_count]) * norm
