import numpy as np

PARAMS = {
    "gain": {"min": -24.0, "max": 12.0, "unit": "dB", "default": 0.0},
}


def process(ctx):
    """
    Process audio buffers.

    Called once per audio render callback. Whole-array numpy ops broadcast
    across channels and frames in one SIMD pass — prefer them over per-channel
    Python loops.

    `ctx` exposes:
        ctx.inputs       2D numpy.float32 array, shape (channels, frame_count)
        ctx.outputs      2D numpy.float32 array, shape (channels, frame_count)
        ctx.sidechain    2D numpy.float32 array, same shape; zero-filled when
                         the host has nothing routed
        ctx.params       read-only view; ctx.params["gain"] or ctx.params.gain
        ctx.state        read-only dict over the bundle-private state buffer
        ctx.telemetry    writable dict — write per-block readouts the UI can show
        ctx.transport    read-only namespace: bpm / beat / is_playing /
                         time_sig_numerator / time_sig_denominator / sample_position
        ctx.sample_rate  current sample rate in Hz (e.g. 44100.0)
        ctx.frame_count  number of valid samples this callback (the 2D arrays
                         are already sliced to this length)
    """
    gain_db = ctx.params["gain"]
    gain = 10.0 ** (gain_db / 20.0)

    np.multiply(ctx.inputs, gain, out=ctx.outputs)
