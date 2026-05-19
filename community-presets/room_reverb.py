import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "size":    param(0.1, 1, default=0.4),
    "damping": param(0, 1, default=0.5),
    "predelay": param(0, 30, unit="ms", default=5),
    "mix":     mix(default=0.25),
}

_combs = None
_aps = None
_pre = None
_lp_state = None

# Base comb times scaled by room size
BASE_COMB = [743, 877, 1013, 1151, 1283, 1409]
BASE_AP = [167, 229, 307]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Room Reverb — small room / studio ambience.

    Simulates the natural reflections of a small to medium room. Short
    decay, moderate density, with early reflections that give a sense
    of physical space. Use subtle for natural ambience on dry
    recordings, or crank it for a live-room drum sound. The everyday
    reverb for mixing vocals, acoustic instruments, and dialogue.

    Params:
        size:     Room size (0.1 = closet, 1 = large room)
        damping:  Wall absorption (0 = reflective, 1 = soft walls)
        predelay: Initial reflection delay (0–30 ms)
        mix:      Wet/dry blend
    """
    global _combs, _aps, _pre, _lp_state

    size = params["size"]
    damping = params["damping"]
    predelay_ms = params["predelay"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _combs is None:
        _combs = [[DelayLine(4096) for _ in BASE_COMB] for _ in range(n_ch)]
        _aps = [[DelayLine(1024) for _ in BASE_AP] for _ in range(n_ch)]
        _pre = [DelayLine(4096) for _ in range(n_ch)]
        _lp_state = [[0.0] * len(BASE_COMB) for _ in range(n_ch)]

    predelay_samples = max(0, int(predelay_ms * 0.001 * sample_rate))

    # Scale comb times by size
    comb_times = [int(ct * (0.5 + size * 0.8)) for ct in BASE_COMB]
    ap_times = [int(at * (0.5 + size * 0.5)) for at in BASE_AP]

    # Short decay for rooms (0.2 to 1.5 seconds based on size)
    decay_s = 0.2 + size * 1.3
    damp = damping * 0.6

    comb_gains = []
    for ct in comb_times:
        comb_gains.append(10.0 ** (-3.0 * ct / (decay_s * sample_rate)))

    for ch in range(n_ch):
        for i in range(frame_count):
            _pre[ch].write(inputs[ch][i])
            x = _pre[ch].tap(predelay_samples) if predelay_samples > 0 else inputs[ch][i]

            comb_sum = 0.0
            for c in range(len(comb_times)):
                ct = min(comb_times[c], _combs[ch][c].max_samples - 1)
                comb_out = _combs[ch][c].tap(ct)
                _lp_state[ch][c] = _lp_state[ch][c] * damp + comb_out * (1.0 - damp)
                _combs[ch][c].write(x + _lp_state[ch][c] * comb_gains[c])
                comb_sum += comb_out

            comb_sum /= len(comb_times)

            y = comb_sum
            for a in range(len(ap_times)):
                at = min(ap_times[a], _aps[ch][a].max_samples - 1)
                ap_out = _aps[ch][a].tap(at)
                ap_in = y - 0.5 * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + 0.5 * ap_in

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
