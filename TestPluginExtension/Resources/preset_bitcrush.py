import numpy as np

# Bitcrush parameters
BIT_DEPTH = 8  # Reduce to this many bits (1-16)
DOWNSAMPLE = 4  # Keep every Nth sample, hold others


def process(inputs, outputs, frame_count, sample_rate):
    """Bitcrush — bit depth reduction and sample rate reduction."""
    levels = 2 ** BIT_DEPTH

    for ch in range(len(inputs)):
        signal = inputs[ch][:frame_count]

        # Bit depth reduction: quantize to fewer levels
        crushed = np.round(signal * levels) / levels

        # Sample rate reduction: hold every Nth sample
        for i in range(frame_count):
            if i % DOWNSAMPLE == 0:
                held = crushed[i]
            outputs[ch][i] = held
