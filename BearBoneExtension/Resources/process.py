import numpy as np

PARAM_NAMES = {
    0: "Param 0", 1: "Param 1", 2: "Param 2", 3: "Param 3",
    4: "Param 4", 5: "Param 5", 6: "Param 6", 7: "Param 7",
}


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
        params:      list of 8 floats (0.0–1.0), the DAW-automatable parameter
                     values (Param 0–7). Use these to control your DSP in real time.
    """
    for ch in range(len(inputs)):
        # Example: apply 0.5x gain (halve the volume)
        outputs[ch][:frame_count] = inputs[ch][:frame_count] * 0.5
