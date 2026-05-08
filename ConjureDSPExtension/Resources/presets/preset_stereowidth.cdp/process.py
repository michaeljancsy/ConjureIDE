import numpy as np
from conjuredsp.params import param

PARAMS = {
    "width": param(0, 2, unit="x", default=1),
}


def process(ctx):
    """
    Stereo Width — mid/side stereo width control.

    Encodes the stereo signal into mid (L+R) and side (L-R) components,
    scales the side component by the width factor, then decodes back to
    L/R. At width=0 the output is mono, at width=1 the signal is
    unchanged, and above 1.0 the stereo image is exaggerated.
    For mono input, the signal passes through unchanged.

    Params:
        width: Stereo width (0.0 = mono, 1.0 = normal, 2.0 = extra wide)
    """
    width = ctx.params["width"]

    n_ch = len(ctx.inputs)

    if n_ch < 2:
        # Mono: passthrough
        ctx.outputs[0][:ctx.frame_count] = ctx.inputs[0][:ctx.frame_count]
        return

    left = ctx.inputs[0][:ctx.frame_count]
    right = ctx.inputs[1][:ctx.frame_count]

    # Encode to mid/side
    mid = (left + right) * 0.5
    side = (left - right) * 0.5

    # Scale side component
    side_scaled = side * width

    # Decode back to L/R
    ctx.outputs[0][:ctx.frame_count] = mid + side_scaled
    ctx.outputs[1][:ctx.frame_count] = mid - side_scaled
