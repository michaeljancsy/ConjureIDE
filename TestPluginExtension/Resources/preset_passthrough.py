import numpy as np


def process(inputs, outputs, frame_count, sample_rate):
    """Passthrough — copies input to output unchanged."""
    for ch in range(len(inputs)):
        outputs[ch][:frame_count] = inputs[ch][:frame_count]
