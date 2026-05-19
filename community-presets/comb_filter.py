import numpy as np
import math
from conjuredsp.params import freq, param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "frequency": freq(min=50, max=2000, default=200),
    "feedback":  param(-0.95, 0.95, default=0.7),
    "mix":       mix(default=0.5),
}

MAX_DELAY = 4096
_delays = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Comb Filter — metallic resonance effect.

    Creates a series of equally-spaced harmonic peaks by feeding a
    short delay back into itself. The frequency control sets the
    fundamental pitch of the resonance. Positive feedback produces
    a bright, metallic ring; negative feedback creates a hollow,
    flanged character with nulls at odd harmonics. Used for metallic
    textures, Karplus-Strong synthesis, and robotic voices.

    Params:
        frequency: Fundamental resonant frequency (50–2000 Hz)
        feedback:  Resonance amount (-0.95 to +0.95)
        mix:       Wet/dry blend
    """
    global _delays

    freq_hz = params["frequency"]
    feedback = params["feedback"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    delay_samples = sample_rate / freq_hz
    delay_samples = max(1.0, min(delay_samples, MAX_DELAY - 1))

    for i in range(frame_count):
        for ch in range(n_ch):
            delayed = _delays[ch].read(delay_samples)
            _delays[ch].write(inputs[ch][i] + delayed * feedback)
            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
