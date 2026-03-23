import numpy as np


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Process audio buffers.

    Called once per audio render callback with pre-allocated numpy arrays.
    Write your processed audio into outputs[ch][:frame_count].

    Args:
        inputs:      list of numpy.float32 arrays, one per channel (pre-allocated,
                     may be longer than frame_count — only [:frame_count] is valid)
        outputs:     list of numpy.float32 arrays, one per channel (pre-allocated,
                     write results into [:frame_count])
        frame_count: number of valid samples this callback (may be < array length)
        sample_rate: current sample rate in Hz (e.g. 44100.0)
        params:      dict of parameter values, keyed by name (if PARAMS is declared),
                     or list of 8 floats 0–1 (legacy mode).
                     Declare a PARAMS dict at module level to define parameters:
                     PARAMS = {"gain": {"min": -24, "max": 12, "unit": "dB", "default": 0}}
    """
    for ch in range(len(inputs)):
        # Example: apply 0.5x gain (halve the volume)
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5
