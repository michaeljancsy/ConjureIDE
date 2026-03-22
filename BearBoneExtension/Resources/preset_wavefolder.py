import numpy as np

# Script-declared parameter names (shown in UI, used in exported AUs)
PARAM_NAMES = {0: "Drive"}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Wavefolder — folds the waveform back when it exceeds +/-1.

    Applies gain (drive) to the input, then uses triangle-wave wrapping
    to fold the signal back into the +/-1 range. Each fold reflects the
    waveform, producing increasingly rich harmonic content as drive increases.
    Unlike clipping, wavefolding preserves energy and creates a distinctive
    metallic/buzzy timbre popular in modular synthesis.

    Params:
        0 (Drive): Fold intensity — 0.0 = 1x, 1.0 = 20x
    """
    drive = 1.0 + params[0] * 19.0  # 1 to 20

    for ch in range(len(inputs)):
        x = inputs[ch][:frame_count] * drive
        # Triangle-wave fold: maps any value into [-1, 1]
        t = (x + 1.0) * 0.25
        t = t - np.floor(t)
        outputs[ch][:frame_count] = 1.0 - np.abs(t * 4.0 - 2.0)
