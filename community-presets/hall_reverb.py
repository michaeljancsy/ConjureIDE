import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "decay":    param(1, 8, unit="s", default=3),
    "damping":  param(0, 1, default=0.4),
    "diffusion": param(0, 1, default=0.7),
    "mix":      mix(default=0.3),
}

# Longer comb times for larger space
COMB_TIMES = [1557, 1733, 1907, 2089, 2243, 2399]
AP_TIMES = [353, 491, 631, 773]
_combs = None
_aps = None
_lp_state = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Hall Reverb — large concert hall simulation.

    Models the long, smooth decay of a large reverberant space. Uses
    more comb filters with longer delay times and additional allpass
    stages for maximum density. The result is a lush, enveloping
    reverb that works beautifully on orchestral instruments, piano,
    vocals, and ambient pads. Think of the reverb in a cathedral
    or concert hall.

    Params:
        decay:     Reverb tail length (1–8 s)
        damping:   Air absorption / high-frequency loss (0–1)
        diffusion: Echo density (0 = sparse, 1 = dense)
        mix:       Wet/dry blend
    """
    global _combs, _aps, _lp_state

    decay_s = params["decay"]
    damping = params["damping"]
    diffusion = params["diffusion"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _combs is None:
        _combs = [[DelayLine(4096) for _ in COMB_TIMES] for _ in range(n_ch)]
        _aps = [[DelayLine(1024) for _ in AP_TIMES] for _ in range(n_ch)]
        _lp_state = [[0.0] * len(COMB_TIMES) for _ in range(n_ch)]

    damp = damping * 0.55
    ap_coeff = 0.3 + diffusion * 0.4

    comb_gains = []
    for ct in COMB_TIMES:
        if decay_s > 0:
            comb_gains.append(10.0 ** (-3.0 * ct / (decay_s * sample_rate)))
        else:
            comb_gains.append(0.0)

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i]

            comb_sum = 0.0
            for c in range(len(COMB_TIMES)):
                comb_out = _combs[ch][c].tap(COMB_TIMES[c])
                _lp_state[ch][c] = _lp_state[ch][c] * damp + comb_out * (1.0 - damp)
                _combs[ch][c].write(x + _lp_state[ch][c] * comb_gains[c])
                comb_sum += comb_out

            comb_sum /= len(COMB_TIMES)

            y = comb_sum
            for a in range(len(AP_TIMES)):
                ap_out = _aps[ch][a].tap(AP_TIMES[a])
                ap_in = y - ap_coeff * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + ap_coeff * ap_in

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
