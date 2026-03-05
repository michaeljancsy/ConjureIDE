import numpy as np

# Hard clip parameters
DRIVE = 3.0  # Pre-clip gain multiplier


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Hard Clip — hard clipping distortion.

    Amplifies the signal by the drive amount, then clips any values
    exceeding ±1.0. Produces a harsh, buzzy distortion with odd harmonics.
    Higher drive values push more of the signal into clipping.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = np.clip(DRIVE * inputs[ch][:frame_count], -1.0, 1.0)
