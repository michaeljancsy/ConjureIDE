import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "rate":     param(0.2, 2, unit="Hz", default=0.5),
    "depth":    param(1, 15, unit="ms", default=5),
    "warmth":   param(0, 1, default=0.4),
    "mix":      mix(default=0.5),
}

MAX_DELAY = 2048
_delays = None
_lp = None
_phases = [0.0, 0.33, 0.67]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Synthwave Chorus — 80s synth chorus (Juno-60 style).

    The lush, wide chorus that defined 80s synth-pop and is now
    the signature sound of synthwave/retrowave. Models the Roland
    Juno-60's BBD chorus: warm filtering, three modulated voices
    with carefully tuned phases, and gentle high-frequency rolloff.
    Apply to any synth pad, bass, or lead for instant 80s width.

    Params:
        rate:   Chorus modulation speed (0.2–2 Hz)
        depth:  Modulation depth (1–15 ms)
        warmth: High-frequency rolloff (0–1)
        mix:    Wet/dry blend
    """
    global _delays, _lp, _phases

    rate = params["rate"]
    depth_ms = params["depth"]
    warmth = params["warmth"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _delays is None:
        _delays = [[DelayLine(MAX_DELAY) for _ in range(3)] for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    depth_samples = depth_ms * 0.001 * sample_rate
    base_delay = depth_samples + 5.0

    # BBD-style rolloff
    lp_freq = 10000.0 - warmth * 6000.0

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

    for i in range(frame_count):
        for ch in range(n_ch):
            x = inputs[ch][i]

            wet = 0.0
            for v in range(3):
                _delays[ch][v].write(x)
                mod = math.sin(two_pi * _phases[v]) * depth_samples
                delay = base_delay + mod
                wet += _delays[ch][v].read_cubic(max(1.0, delay))

            wet /= 3.0

            # BBD warmth
            wet = _lp[ch].process_sample(wet)

            outputs[ch][i] = x * (1.0 - wet_mix) + wet * wet_mix

        for v in range(3):
            voice_rate = rate * (0.9 + 0.2 * v / 2.0)
            _phases[v] = (_phases[v] + voice_rate / sample_rate) % 1.0
