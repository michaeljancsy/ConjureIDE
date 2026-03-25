import numpy as np

PARAMS = {
    "drive": {"min": 1.0, "max": 20.0, "unit": "x", "default": 5.0},
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Wavefolder — folds the waveform back when it exceeds +/-1.

    Applies gain (drive) to the input, then uses triangle-wave wrapping
    to fold the signal back into the +/-1 range. Each fold reflects the
    waveform, producing increasingly rich harmonic content as drive increases.
    Unlike clipping, wavefolding preserves energy and creates a distinctive
    metallic/buzzy timbre popular in modular synthesis.

    Params:
        drive: Fold intensity (1–20x)
    """
    drive = params["drive"]

    for ch in range(len(inputs)):
        x = outputs[ch][:frame_count]
        np.multiply(inputs[ch][:frame_count], drive, out=x)
        # Triangle-wave fold: maps any value into [-1, 1]
        t = (x + 1.0) * 0.25
        t = t - np.floor(t)
        outputs[ch][:frame_count] = 1.0 - np.abs(t * 4.0 - 2.0)
