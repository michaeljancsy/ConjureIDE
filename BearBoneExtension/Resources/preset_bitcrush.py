import numpy as np

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Bit Depth", 1: "Downsample"}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Bitcrush — bit depth reduction and sample rate reduction.

    Applies two lo-fi effects in series:
    1. Bit depth reduction: quantizes the signal to fewer amplitude levels,
       producing a gritty, digital distortion.
    2. Sample rate reduction: holds every Nth sample, discarding the rest,
       which introduces aliasing artifacts and a characteristic stepped sound.

    Params:
        0 (Bit Depth):  1–16 bits
        1 (Downsample): 1–16x sample rate reduction
    """
    bit_depth = int(params[0] * 15) + 1   # 1 to 16
    downsample = int(params[1] * 15) + 1  # 1 to 16
    levels = 2 ** bit_depth

    for ch in range(len(inputs)):
        signal = inputs[ch][:frame_count]

        # Bit depth reduction: quantize to fewer levels
        crushed = np.round(signal * levels) / levels

        # Sample rate reduction: hold every Nth sample
        for i in range(frame_count):
            if i % downsample == 0:
                held = crushed[i]
            outputs[ch][i] = held
