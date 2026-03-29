import numpy as np
import math
from conjuredsp.params import db, param
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "peak_reduction": db(0, 40, default=15),
    "gain":           db(0, 30, default=10),
    "speed":          param(0, 1, default=0.5),
}

_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Opto Compressor — LA-2A style optical compressor.

    Models the program-dependent behavior of an optical compressor.
    The photocell/light element has inherently slow, musical attack
    and release characteristics that depend on the signal — fast
    transients get through while sustained levels are gently
    compressed. The LA-2A is THE vocal compressor, also beloved
    for bass, acoustic guitar, and bus compression. Simple two-knob
    operation: Peak Reduction (threshold/ratio) and Gain (makeup).

    Params:
        peak_reduction: Compression amount (0–40 dB)
        gain:           Makeup gain (0–30 dB)
        speed:          Optical element speed (0 = slow/smooth, 1 = fast)
    """
    global _envelope

    peak_red_db = params["peak_reduction"]
    makeup = db_to_gain(params["gain"])
    speed = params["speed"]

    # Opto element: program-dependent attack/release
    # Attack: 1.5-10 ms, Release: 40-500 ms (faster at speed=1)
    attack_ms = 10.0 - speed * 8.5
    release_ms = 500.0 - speed * 460.0

    att = smooth_coeff(attack_ms, sample_rate)
    rel = smooth_coeff(release_ms, sample_rate)

    # Opto threshold is fixed; peak_reduction controls the sensitivity
    threshold = db_to_gain(-peak_red_db)

    for i in range(frame_count):
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        # Program-dependent envelope (opto characteristic)
        # The "speed" depends on signal level — louder = faster response
        level_factor = 1.0 + peak * 2.0
        if peak > _envelope:
            _envelope = att * _envelope + (1.0 - att) * peak * level_factor
            _envelope = min(_envelope, peak)
        else:
            _envelope = rel * _envelope + (1.0 - rel) * peak

        # Soft-knee compression (opto elements have gradual onset)
        if _envelope > threshold and _envelope > 1e-10:
            ratio_db = 20.0 * math.log10(_envelope / threshold + 1e-30)
            # Soft knee: ratio increases with level (program-dependent)
            effective_ratio = 2.0 + ratio_db * 0.3
            db_reduction = ratio_db * (1.0 - 1.0 / effective_ratio)
            gain = 10.0 ** (-db_reduction / 20.0)
        else:
            gain = 1.0

        for ch in range(len(inputs)):
            outputs[ch][i] = inputs[ch][i] * gain * makeup
