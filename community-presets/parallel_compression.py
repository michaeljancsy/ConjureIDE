import numpy as np
import math
from conjuredsp.params import db, ratio, time_ms, param
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "threshold": db(-40, -5, default=-30),
    "ratio":     ratio(4, 20, default=10),
    "attack":    time_ms(min=0.5, max=30, default=3),
    "release":   time_ms(min=20, max=300, default=80),
    "blend":     param(0, 1, default=0.4),
}

_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Parallel Compression — New York compression.

    Blends heavily compressed audio with the uncompressed original.
    The compressed signal brings up low-level details and sustain
    while the dry signal preserves natural transients. The result
    is a thick, punchy sound with both impact and density. Named
    after the NYC studio technique — the secret weapon for drum
    buses, vocals, and aggressive mixes.

    Params:
        threshold: Compression threshold (-40 to -5 dB)
        ratio:     Compression ratio (4:1 to 20:1 — crush it!)
        attack:    Attack time (0.5–30 ms)
        release:   Release time (20–300 ms)
        blend:     Compressed signal blend (0 = dry only, 1 = compressed only)
    """
    global _envelope

    threshold = db_to_gain(params["threshold"])
    comp_ratio = params["ratio"]
    att = smooth_coeff(params["attack"], sample_rate)
    rel = smooth_coeff(params["release"], sample_rate)
    blend = params["blend"]

    gain_arr = np.ones(frame_count, dtype=np.float32)

    for i in range(frame_count):
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        if peak > _envelope:
            _envelope = att * _envelope + (1.0 - att) * peak
        else:
            _envelope = rel * _envelope + (1.0 - rel) * peak

        if _envelope > threshold:
            db_over = 20.0 * math.log10(_envelope / threshold + 1e-30)
            db_red = db_over * (1.0 - 1.0 / comp_ratio)
            gain_arr[i] = 10.0 ** (-db_red / 20.0)

    # Makeup gain to match compressed to dry level
    makeup = db_to_gain(20.0 * math.log10(1.0 / threshold + 1e-30) * (1.0 - 1.0 / comp_ratio) * 0.5)

    for ch in range(len(inputs)):
        dry = inputs[ch][:frame_count]
        compressed = dry * gain_arr * makeup

        # Parallel blend
        outputs[ch][:frame_count] = dry * (1.0 - blend) + compressed * blend
