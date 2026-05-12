import numpy as np


def process(ctx):
    """
    Passthrough — copies input audio to output unchanged.

    The simplest possible DSP script. ctx.inputs / ctx.outputs are 2D arrays
    of shape (channels, frame_count), pre-sliced; np.copyto broadcasts across
    both axes in one call.
    """
    np.copyto(ctx.outputs, ctx.inputs)
