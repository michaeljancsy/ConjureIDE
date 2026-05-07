import numpy as np

PARAMS = {
    "gain": {"min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0},
}


def process(ctx):
    """
    Process audio buffers.

    Called once per audio render callback with pre-allocated numpy arrays.
    Write your processed audio into ctx.outputs[ch][:ctx.frame_count].

    `ctx` exposes:
        ctx.inputs       list of numpy.float32 arrays, one per channel
        ctx.outputs      list of numpy.float32 arrays, one per channel
        ctx.sidechain    list of numpy.float32 arrays (always populated;
                         zero-filled when host has nothing routed)
        ctx.params       read-only dict of actual parameter values keyed by PARAMS name
        ctx.state        read-only dict over the bundle-private state buffer
        ctx.telemetry    writable dict — write per-block readouts the UI can show
        ctx.transport    read-only namespace: bpm / beat / is_playing /
                         time_sig_numerator / time_sig_denominator / sample_position
        ctx.sample_rate  current sample rate in Hz (e.g. 44100.0)
        ctx.frame_count  number of valid samples this callback
    """
    gain_db = ctx.params["gain"]
    gain = 10.0 ** (gain_db / 20.0)

    for ch in range(len(ctx.inputs)):
        np.multiply(
            ctx.inputs[ch][:ctx.frame_count],
            gain,
            out=ctx.outputs[ch][:ctx.frame_count],
        )
