import numpy as np


def process(inputs, outputs, frame_count, sample_rate):
    """
    Process audio buffers.

    Args:
        inputs:  list of numpy.float32 arrays (pre-allocated, max_frames long)
        outputs: list of numpy.float32 arrays (pre-allocated, max_frames long)
        frame_count: number of valid samples this callback (may be < array length)
        sample_rate: current sample rate (e.g. 44100.0)

    Write your processed audio into outputs[ch][:frame_count].
    """
    for ch in range(len(inputs)):
        # Example: apply 0.5x gain (halve the volume)
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5
