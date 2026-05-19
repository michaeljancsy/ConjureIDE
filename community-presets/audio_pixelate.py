import numpy as np
from conjuredsp.params import param, mix

PARAMS = {
    "block_size": param(2, 512, default=64),
    "mix":        mix(default=0.7),
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Audio Pixelate — block-based audio reduction.

    Divides audio into blocks and replaces each block with its
    average value, like pixelating an image. Small blocks create
    subtle graininess; large blocks create a stepped, blocky sound.
    Unlike sample-and-hold (which repeats single samples), this
    averages over the block — creating a unique, chunky texture.
    Great for lo-fi, glitch, and abstract sound design.

    Params:
        block_size: Number of samples per "pixel" (2–512)
        mix:        Wet/dry blend
    """
    block = max(2, int(params["block_size"]))
    wet_mix = params["mix"]

    for ch in range(len(inputs)):
        for start in range(0, frame_count, block):
            end = min(start + block, frame_count)

            # Average the block
            avg = 0.0
            count = 0
            for i in range(start, end):
                avg += inputs[ch][i]
                count += 1
            avg /= count

            # Fill block with average
            for i in range(start, end):
                outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + avg * wet_mix
