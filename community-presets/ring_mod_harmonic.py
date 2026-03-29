import numpy as np
import math
from conjuredsp.params import freq, param, mix

PARAMS = {
    "frequency": freq(min=20, max=5000, default=440),
    "shape":     param(0, 1, default=0),
    "mix":       mix(default=0.5),
}

_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ring Modulator — harmonic ring modulation.

    Multiplies the input by a carrier oscillator, creating sum and
    difference frequencies. When the carrier is harmonically related
    to the input, produces musical overtones. When inharmonic,
    creates metallic, bell-like, or alien textures. The shape
    control morphs the carrier from sine (smooth) to square
    (aggressive). Classic Dalek voice, sci-fi sound design, and
    experimental guitar effect.

    Params:
        frequency: Carrier frequency (20–5000 Hz)
        shape:     Carrier shape (0 = sine, 1 = square)
        mix:       Wet/dry blend
    """
    global _phase

    carrier_freq = params["frequency"]
    shape = params["shape"]
    wet_mix = params["mix"]

    two_pi = 2.0 * math.pi

    for i in range(frame_count):
        # Morphable carrier: sine → square
        sine = math.sin(two_pi * _phase)
        if shape < 0.01:
            carrier = sine
        else:
            # Crossfade between sine and hard-limited sine (square)
            square = 1.0 if sine >= 0 else -1.0
            carrier = sine * (1.0 - shape) + square * shape

        for ch in range(len(inputs)):
            x = inputs[ch][i]
            ring = x * carrier
            outputs[ch][i] = x * (1.0 - wet_mix) + ring * wet_mix

        _phase = (_phase + carrier_freq / sample_rate) % 1.0
