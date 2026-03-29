import numpy as np
from conjuredsp.params import db, choice
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "mode":     choice("Encode", "Decode", default="Encode"),
    "mid_gain": db(-12, 12, default=0),
    "side_gain": db(-12, 12, default=0),
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Mid/Side Processor — stereo field manipulation.

    Encode mode converts L/R to Mid/Side, allowing independent
    gain control of the center (mid) and sides (side) of the
    stereo field. Boost mid for a more focused, centered mix;
    boost side for wider stereo. Cut side for mono compatibility.
    Decode mode converts back from M/S to L/R. Use two instances
    (encode → processing → decode) for M/S processing chains.

    Params:
        mode:      Encode (L/R→M/S) or Decode (M/S→L/R)
        mid_gain:  Center channel gain (-12 to +12 dB)
        side_gain: Side channel gain (-12 to +12 dB)
    """
    mode = int(params["mode"])
    mid_g = db_to_gain(params["mid_gain"])
    side_g = db_to_gain(params["side_gain"])

    n_ch = len(inputs)

    if n_ch < 2:
        # Mono: just pass through
        outputs[0][:frame_count] = inputs[0][:frame_count]
        return

    if mode == 0:  # Encode: L/R → M/S
        for i in range(frame_count):
            left = inputs[0][i]
            right = inputs[1][i]

            mid = (left + right) * 0.5 * mid_g
            side = (left - right) * 0.5 * side_g

            outputs[0][i] = mid
            outputs[1][i] = side
    else:  # Decode: M/S → L/R
        for i in range(frame_count):
            mid = inputs[0][i] * mid_g
            side = inputs[1][i] * side_g

            outputs[0][i] = mid + side
            outputs[1][i] = mid - side
