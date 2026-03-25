import numpy as np

PARAMS = {
    "width": {"min": 0.0, "max": 2.0, "unit": "x", "default": 1.0},
}

# Pre-allocated scratch buffers for mid/side (avoids per-callback allocations)
_scratch_mid = None
_scratch_side = None


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
    global _scratch_mid, _scratch_side

    width = params["width"]

    n_ch = len(inputs)

    if n_ch < 2:
        # Mono: passthrough
        outputs[0][:frame_count] = inputs[0][:frame_count]
        return

    # Ensure scratch buffers are large enough
    if _scratch_mid is None or len(_scratch_mid) < frame_count:
        _scratch_mid = np.empty(frame_count, dtype=np.float32)
        _scratch_side = np.empty(frame_count, dtype=np.float32)

    left = inputs[0][:frame_count]
    right = inputs[1][:frame_count]
    mid = _scratch_mid[:frame_count]
    side = _scratch_side[:frame_count]

    # Encode to mid/side
    np.add(left, right, out=mid)
    np.multiply(mid, 0.5, out=mid)
    np.subtract(left, right, out=side)
    np.multiply(side, 0.5, out=side)

    # Scale side component
    np.multiply(side, width, out=side)

    # Decode back to L/R
    np.add(mid, side, out=outputs[0][:frame_count])
    np.subtract(mid, side, out=outputs[1][:frame_count])
