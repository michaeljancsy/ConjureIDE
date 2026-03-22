import numpy as np

# Parameters:
DRIVE = 0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Soft Clip — tanh waveshaping saturation.

    Applies a smooth, warm saturation by passing the signal through a
    hyperbolic tangent function. The drive parameter controls how hard
    the signal is pushed into the nonlinearity. Output is normalized
    so that low-level signals pass through at unity gain.

    Params:
        0 (Drive): Saturation amount — 0.0 = 1x, 1.0 = 15x
    """
    drive = 1.0 + params[DRIVE] * 14.0  # 1 to 15
    norm = 1.0 / np.tanh(drive)

    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = np.tanh(drive * inputs[ch][:frame_count]) * norm
