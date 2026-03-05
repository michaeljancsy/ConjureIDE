import numpy as np

# Soft clip parameters
DRIVE = 3.0  # Higher = more saturation

# Normalize so that at drive=1, unity gain is preserved
NORM = 1.0 / np.tanh(DRIVE)


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Soft Clip — tanh waveshaping saturation.

    Applies a smooth, warm saturation by passing the signal through a
    hyperbolic tangent function. The drive parameter controls how hard
    the signal is pushed into the nonlinearity. Output is normalized
    so that low-level signals pass through at unity gain.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = np.tanh(DRIVE * inputs[ch][:frame_count]) * NORM
