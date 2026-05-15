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

    Controls:
        width: Stereo width (0.0 = mono, 1.0 = normal, 2.0 = extra wide)
    """
    width = ctx.params["width"]

    if ctx.inputs.shape[0] < 2:
        # Mono: passthrough.
        ctx.outputs[:] = ctx.inputs
        return

    left = ctx.inputs[0]
    right = ctx.inputs[1]

    # Encode to mid/side, scale, decode back. Each line is a whole-row
    # numpy op — no Python loop, no slack-region slicing needed.
    mid = (left + right) * 0.5
    side = (left - right) * 0.5 * width

    ctx.outputs[0] = mid + side
    ctx.outputs[1] = mid - side
