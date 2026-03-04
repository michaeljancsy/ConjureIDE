import numpy as np

# Wavefolder parameters
DRIVE = 3.0  # Higher = more folds, richer harmonics


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Wavefolder — folds the waveform back when it exceeds ±1.

    Applies gain (drive) to the input, then uses triangle-wave wrapping
    to fold the signal back into the ±1 range. Each fold reflects the
    waveform, producing increasingly rich harmonic content as drive increases.
    Unlike clipping, wavefolding preserves energy and creates a distinctive
    metallic/buzzy timbre popular in modular synthesis.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz
        params:      list of 8 floats (0.0–1.0), DAW-automatable parameters (unused)
    """
    for ch in range(len(inputs)):
        x = inputs[ch][:frame_count] * DRIVE
        # Triangle-wave fold: maps any value into [-1, 1]
        t = (x + 1.0) * 0.25
        t = t - np.floor(t)
        outputs[ch][:frame_count] = 1.0 - np.abs(t * 4.0 - 2.0)
