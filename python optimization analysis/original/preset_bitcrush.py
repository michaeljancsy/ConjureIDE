import numpy as np

PARAMS = {
    "bit_depth":  {"min": 1, "max": 16, "unit": "bits", "default": 8},
    "downsample": {"min": 1, "max": 16, "unit": "x",    "default": 1},
}


def process(inputs, outputs, frame_count, sample_rate, params):
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
    bit_depth = int(params["bit_depth"])
    downsample = int(params["downsample"])
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
