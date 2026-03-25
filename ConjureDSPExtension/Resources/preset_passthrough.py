import numpy as np


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Passthrough — copies input audio to output unchanged.

    This is the simplest possible DSP script. Each channel's input samples
    are copied directly to the corresponding output buffer with no modification.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count]
