import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "decay":   param(1, 10, unit="s", default=4),
    "shimmer": param(0, 1, default=0.6),
    "damping": param(0, 1, default=0.3),
    "mix":     mix(default=0.4),
}

COMB_TIMES = [1187, 1307, 1439, 1553]
AP_TIMES = [277, 389]
_combs = None
_aps = None
_lp_state = None
_shimmer_phase = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Shimmer Reverb — pitch-shifted ethereal reverb tails.

    Combines a lush reverb with octave-up pitch shifting in the
    feedback loop. Each cycle through the reverb, the signal shifts
    up, creating infinite ascending crystalline tails. The signature
    sound of ambient, post-rock, and cinematic music. Popularized
    by Strymon BigSky and Eventide Space pedals.

    Params:
        decay:   Reverb tail length (1–10 s)
        shimmer: Octave-shift amount in feedback (0–1)
        damping: High-frequency loss (0–1)
        mix:     Wet/dry blend
    """
    global _combs, _aps, _lp_state, _shimmer_phase

    decay_s = params["decay"]
    shimmer = params["shimmer"]
    damping = params["damping"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _combs is None:
        _combs = [[DelayLine(2048) for _ in COMB_TIMES] for _ in range(n_ch)]
        _aps = [[DelayLine(512) for _ in AP_TIMES] for _ in range(n_ch)]
        _lp_state = [[0.0] * len(COMB_TIMES) for _ in range(n_ch)]

    damp = damping * 0.5

    comb_gains = []
    for ct in COMB_TIMES:
        if decay_s > 0:
            comb_gains.append(10.0 ** (-3.0 * ct / (decay_s * sample_rate)))
        else:
            comb_gains.append(0.0)

    two_pi = 2.0 * math.pi

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i]

            # Parallel comb filters
            comb_sum = 0.0
            for c in range(len(COMB_TIMES)):
                comb_out = _combs[ch][c].tap(COMB_TIMES[c])

                # Damping in feedback
                _lp_state[ch][c] = _lp_state[ch][c] * damp + comb_out * (1.0 - damp)

                # Shimmer: ring-mod octave up in feedback
                shimmer_sig = _lp_state[ch][c] * math.sin(two_pi * _shimmer_phase[ch] * 2.0)
                fb = _lp_state[ch][c] * (1.0 - shimmer) + shimmer_sig * shimmer

                _combs[ch][c].write(x + fb * comb_gains[c])
                comb_sum += comb_out

            comb_sum /= len(COMB_TIMES)

            # Allpass diffusers
            y = comb_sum
            for a in range(len(AP_TIMES)):
                ap_out = _aps[ch][a].tap(AP_TIMES[a])
                ap_in = y - 0.5 * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + 0.5 * ap_in

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix

        _shimmer_phase[ch] = (_shimmer_phase[ch] + 440.0 / sample_rate) % 1.0
