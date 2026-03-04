import numpy as np

# Bitcrush parameters
BIT_DEPTH = 8  # Reduce to this many bits (1-16)
DOWNSAMPLE = 4  # Keep every Nth sample, hold others


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Bitcrush — bit depth reduction and sample rate reduction.

    Applies two lo-fi effects in series:
    1. Bit depth reduction: quantizes the signal to fewer amplitude levels,
       producing a gritty, digital distortion.
    2. Sample rate reduction: holds every Nth sample, discarding the rest,
       which introduces aliasing artifacts and a characteristic stepped sound.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
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
