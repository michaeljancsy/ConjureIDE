import numpy as np

PARAMS = {
    "gain": {"min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0},
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Process audio buffers.

    Called once per audio render callback with pre-allocated numpy arrays.
    Write your processed audio into outputs[ch][:frame_count].

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz (e.g. 44100.0)
        params:      dict of actual parameter values keyed by PARAMS name
    """
    gain_db = params["gain"]
    gain = 10.0 ** (gain_db / 20.0)

    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], gain, out=outputs[ch][:frame_count])
