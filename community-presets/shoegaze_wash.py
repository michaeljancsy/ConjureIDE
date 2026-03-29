import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "depth":    param(0, 1, default=0.8),
    "feedback": param(0, 0.95, default=0.7),
    "shimmer":  param(0, 1, default=0.5),
    "mix":      mix(default=0.8),
}

MAX_DELAY = 4096
COMB_TIMES = [1087, 1237, 1381, 1523]
_chorus_delays = None
_rev_combs = None
_rev_lp = None
_phases = [0.0, 0.12, 0.37, 0.55]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Shoegaze Wash — wall of sound shoegaze effect.

    Combines deep modulated chorus with dense, long-tailed reverb
    to create the massive, blurred wall of sound that defines
    shoegaze. The shimmer control adds overtone content for extra
    density. Designed for the My Bloody Valentine, Slowdive, and
    Cocteau Twins guitar sound — where individual notes dissolve
    into a beautiful, overwhelming texture.

    Params:
        depth:    Chorus/modulation depth (0–1)
        feedback: Reverb density and length (0–0.95)
        shimmer:  Overtone shimmer amount (0–1)
        mix:      Effect blend (higher = more washed out)
    """
    global _chorus_delays, _rev_combs, _rev_lp, _phases

    depth = params["depth"]
    feedback = params["feedback"]
    shimmer = params["shimmer"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _chorus_delays is None:
        _chorus_delays = [[DelayLine(MAX_DELAY) for _ in range(3)] for _ in range(n_ch)]
        _rev_combs = [[DelayLine(2048) for _ in COMB_TIMES] for _ in range(n_ch)]
        _rev_lp = [[0.0] * len(COMB_TIMES) for _ in range(n_ch)]

    mod_depth = depth * 8.0
    rates = [0.3, 0.47, 0.71]

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i]

            # Deep multi-voice chorus
            chorus_out = 0.0
            for v in range(3):
                _chorus_delays[ch][v].write(x)
                mod = math.sin(two_pi * _phases[v]) * mod_depth
                delay = 10.0 + mod
                chorus_out += _chorus_delays[ch][v].read_cubic(max(1.0, delay))
            chorus_out /= 3.0

            # Dense reverb
            rev_in = (x + chorus_out) * 0.5
            rev_out = 0.0
            for c in range(len(COMB_TIMES)):
                comb_out = _rev_combs[ch][c].tap(COMB_TIMES[c])
                _rev_lp[ch][c] = _rev_lp[ch][c] * 0.3 + comb_out * 0.7

                # Shimmer in reverb feedback
                fb_signal = _rev_lp[ch][c]
                if shimmer > 0:
                    fb_signal = fb_signal * (1.0 - shimmer * 0.3) + abs(fb_signal) * shimmer * 0.3

                _rev_combs[ch][c].write(rev_in + fb_signal * feedback)
                rev_out += comb_out

            rev_out /= len(COMB_TIMES)

            wet = chorus_out * 0.4 + rev_out * 0.6
            outputs[ch][i] = x * (1.0 - wet_mix) + wet * wet_mix

    for v in range(len(_phases)):
        r = rates[v] if v < len(rates) else 0.5
        _phases[v] = (_phases[v] + r / sample_rate) % 1.0
