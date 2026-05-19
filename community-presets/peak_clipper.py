import numpy as np
import math
from conjuredsp.params import db
from conjuredsp.dsp import db_to_gain

PARAMS = {
    "ceiling": db(-6, 0, default=-1),
    "input":   db(0, 12, default=3),
}


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Peak Clipper — mastering-grade hard/soft clipper.

    Drives the signal into a ceiling with soft-knee clipping. Unlike
    a limiter, clipping is instantaneous (zero attack time) which
    preserves transient shape while removing peaks. At moderate
    settings, adds loudness transparently. The last stage before
    limiting in many mastering chains. Also used as a drum bus trick
    for aggressive, loud mixes.

    Params:
        ceiling: Clipping ceiling (-6 to 0 dB)
        input:   Input gain / drive into the clipper (0–12 dB)
    """
    ceiling = db_to_gain(params["ceiling"])
    input_gain = db_to_gain(params["input"])

    for ch in range(len(inputs)):
        signal = inputs[ch][:frame_count] * input_gain

        # Soft clip with smooth knee approaching ceiling
        for i in range(frame_count):
            x = signal[i]
            # Normalize to ceiling
            x_norm = x / ceiling

            # Soft clip using tanh-based curve
            if abs(x_norm) > 0.5:
                # Blend from linear to tanh near ceiling
                y = math.tanh(x_norm * 1.5) / math.tanh(1.5)
            else:
                y = x_norm

            outputs[ch][i] = y * ceiling
