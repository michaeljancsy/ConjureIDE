import numpy as np
import math
from conjuredsp.params import param, db
from conjuredsp.dsp import db_to_gain, smooth_coeff

PARAMS = {
    "sustain": param(0, 1, default=0.6),
    "attack":  param(0, 1, default=0.3),
    "level":   db(-12, 6, default=0),
}

_envelope = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Compressor Sustainer — guitar sustain pedal.

    Designed for guitar: heavy compression that extends note sustain
    while keeping the attack natural. The sustain knob controls
    compression intensity. The attack control determines how much
    pick transient comes through. At high sustain, notes ring out
    endlessly. The foundation of every guitarist's pedalboard —
    think MXR Dyna Comp, Ross Compressor, or Keeley Compressor.

    Params:
        sustain: Compression amount (0 = light, 1 = infinite sustain)
        attack:  Transient preservation (0 = squashed, 1 = natural pick)
        level:   Output level (-12 to +6 dB)
    """
    global _envelope

    sustain = params["sustain"]
    attack = params["attack"]
    level = db_to_gain(params["level"])

    # Map sustain to compression parameters
    threshold = db_to_gain(-5.0 - sustain * 35.0)
    comp_ratio = 2.0 + sustain * 18.0

    attack_ms = 0.5 + attack * 30.0
    release_ms = 50.0 + sustain * 300.0

    att = smooth_coeff(attack_ms, sample_rate)
    rel = smooth_coeff(release_ms, sample_rate)

    for i in range(frame_count):
        peak = 0.0
        for ch in range(len(inputs)):
            peak = max(peak, abs(inputs[ch][i]))

        if peak > _envelope:
            _envelope = att * _envelope + (1.0 - att) * peak
        else:
            _envelope = rel * _envelope + (1.0 - rel) * peak

        gain = 1.0
        if _envelope > threshold:
            db_over = 20.0 * math.log10(_envelope / threshold + 1e-30)
            db_red = db_over * (1.0 - 1.0 / comp_ratio)
            gain = 10.0 ** (-db_red / 20.0)

        # Auto makeup based on threshold
        makeup = 1.0 / max(threshold, 0.01) * 0.3

        for ch in range(len(inputs)):
            outputs[ch][i] = inputs[ch][i] * gain * makeup * level
