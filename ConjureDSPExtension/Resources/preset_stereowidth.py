import numpy as np

PARAMS = {
    "width": {"min": 0.0, "max": 2.0, "unit": "x", "default": 1.0},
}


def process(inputs, outputs, frame_count, sample_rate, params):
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
    width = params["width"]

    n_ch = len(inputs)

    if n_ch < 2:
        # Mono: passthrough
        outputs[0][:frame_count] = inputs[0][:frame_count]
        return

    left = inputs[0][:frame_count]
    right = inputs[1][:frame_count]

    # Encode to mid/side
    mid = (left + right) * 0.5
    side = (left - right) * 0.5

    # Scale side component
    side_scaled = side * width

    # Decode back to L/R
    outputs[0][:frame_count] = mid + side_scaled
    outputs[1][:frame_count] = mid - side_scaled
