import numpy as np
from conjuredsp.params import integer

PARAMS = {
    "bit_depth":  integer(1, 16, unit="bits", default=8),
    "downsample": integer(1, 16, unit="x", default=1),
}


def process(ctx):
    """
    Bitcrush — bit depth reduction and sample rate reduction.

    Applies two lo-fi effects in series:
    1. Bit depth reduction: quantizes the signal to fewer amplitude levels,
       producing a gritty, digital distortion.
    2. Sample rate reduction: holds every Nth sample, discarding the rest,
       which introduces aliasing artifacts and a characteristic stepped sound.

    Params:
        bit_depth:  Quantization depth (1–16 bits)
        downsample: Sample rate reduction factor (1–16x)
    """
    bit_depth = int(ctx.params["bit_depth"])
    downsample = int(ctx.params["downsample"])
    levels = 2 ** bit_depth

    for ch in range(len(ctx.inputs)):
        signal = ctx.inputs[ch][:ctx.frame_count]

        # Bit depth reduction: quantize to fewer levels.
        # Use half-away-from-zero rounding (matches Rust f32::round) rather than
        # numpy's default banker's rounding, so the Python and Rust backends
        # produce bit-identical output.
        scaled = signal * levels
        crushed = np.trunc(scaled + np.sign(scaled) * 0.5) / levels

        # Sample rate reduction: hold every Nth sample
        for i in range(ctx.frame_count):
            if i % downsample == 0:
                held = crushed[i]
            ctx.outputs[ch][i] = held
