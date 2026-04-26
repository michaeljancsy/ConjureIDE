import numpy as np

PARAMS = {
    "gain": {"min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0},
}


def process(inputs, outputs, frame_count, sample_rate, params, _transport, _telemetry):
    """
    Process audio buffers.

    Called once per audio render callback with pre-allocated numpy arrays.
    Write your processed audio into outputs[ch][:frame_count].

    Always declare all 7 args, even if you don't use transport or
    telemetry — this matches the canonical ConjureDSP convention. Drop
    the underscore from `_transport` / `_telemetry` when you start
    using them.

    Args:
        inputs:      list of numpy.float32 arrays, one per channel
        outputs:     list of numpy.float32 arrays, one per channel
        frame_count: number of valid samples this callback
        sample_rate: current sample rate in Hz (e.g. 44100.0)
        params:      dict of actual parameter values keyed by PARAMS name
        _transport:  dict with tempo/beat/playing/time_sig_num/time_sig_den/sample_pos
        _telemetry:  dict — write per-block readouts the UI can show
    """
    gain_db = params["gain"]
    gain = 10.0 ** (gain_db / 20.0)

    for ch in range(len(inputs)):
        np.multiply(inputs[ch][:frame_count], gain, out=outputs[ch][:frame_count])
