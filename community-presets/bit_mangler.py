import numpy as np
import math
import random
from conjuredsp.params import param, mix

PARAMS = {
    "corrupt":   param(0, 1, default=0.5),
    "xor_mask":  param(0, 255, default=42),
    "sample_rate": param(1, 32, unit="x", default=4),
    "mix":       mix(default=0.7),
}

_held = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Bit Mangler — extreme digital destruction.

    Treats audio as raw binary data and corrupts it through bit
    manipulation: XOR operations flip bits creating tonal patterns,
    sample-rate reduction creates aliasing, and random bit flips
    add chaos. The corrupt control goes from subtle glitches to
    total destruction. For when bitcrushing isn't harsh enough.
    Used in noise music, industrial, and glitch art.

    Params:
        corrupt:     Overall corruption intensity (0–1)
        xor_mask:    XOR bit pattern (0–255) — different values create different tonal patterns
        sample_rate: Downsampling factor (1–32x)
        mix:         Wet/dry blend
    """
    corrupt = params["corrupt"]
    xor_val = int(params["xor_mask"])
    downsample = max(1, int(params["sample_rate"]))
    wet_mix = params["mix"]

    for ch in range(len(inputs)):
        for i in range(frame_count):
            x = inputs[ch][i]

            # Convert to 16-bit integer representation
            x_int = int(max(-32768, min(32767, x * 32768.0)))

            # XOR corruption
            if corrupt > 0.3:
                x_int = x_int ^ xor_val

            # Random bit flips
            if corrupt > 0.6 and random.random() < corrupt * 0.1:
                bit = 1 << random.randint(0, 15)
                x_int = x_int ^ bit

            # Convert back to float
            y = x_int / 32768.0

            # Sample rate reduction
            if i % downsample == 0:
                _held[ch] = y
            y = _held[ch]

            outputs[ch][i] = x * (1.0 - wet_mix) + y * wet_mix
