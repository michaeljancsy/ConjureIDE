import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "decay":   param(0.2, 5, unit="s", default=1.5),
    "damping": param(0, 1, default=0.4),
    "predelay": param(0, 50, unit="ms", default=10),
    "mix":     mix(default=0.3),
}

# Prime-number based delay lengths for dense reverb
COMB_TIMES = [1117, 1277, 1399, 1523, 1637, 1777]
AP_TIMES = [241, 337, 431]
MAX_COMB = 2048
MAX_AP = 512

_combs = None
_aps = None
_predelay_line = None
_lp = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Plate Reverb — EMT 140 inspired metallic plate simulation.

    Models a vibrating metal plate using parallel comb filters feeding
    into series allpass diffusers. Plate reverbs have a dense, bright,
    slightly metallic character that's perfect for vocals, snare drums,
    and keyboards. The EMT 140 defined the reverb sound of the 60s-80s,
    used on countless hit records.

    Params:
        decay:    Reverb tail length (0.2–5 s)
        damping:  High-frequency absorption (0 = bright, 1 = dark)
        predelay: Gap before reverb onset (0–50 ms)
        mix:      Wet/dry blend
    """
    global _combs, _aps, _predelay_line, _lp

    decay_s = params["decay"]
    damping = params["damping"]
    predelay_ms = params["predelay"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _combs is None:
        _combs = [[DelayLine(MAX_COMB) for _ in COMB_TIMES] for _ in range(n_ch)]
        _aps = [[DelayLine(MAX_AP) for _ in AP_TIMES] for _ in range(n_ch)]
        _predelay_line = [DelayLine(int(0.05 * 96000) + 100) for _ in range(n_ch)]
        _lp = [[0.0] * len(COMB_TIMES) for _ in range(n_ch)]

    predelay_samples = max(0, int(predelay_ms * 0.001 * sample_rate))

    # Compute feedback gains for desired decay time per comb
    comb_gains = []
    for ct in COMB_TIMES:
        if decay_s > 0:
            comb_gains.append(10.0 ** (-3.0 * ct / (decay_s * sample_rate)))
        else:
            comb_gains.append(0.0)

    damp = damping * 0.5

    for ch in range(n_ch):
        for i in range(frame_count):
            # Predelay
            _predelay_line[ch].write(inputs[ch][i])
            x = _predelay_line[ch].tap(predelay_samples) if predelay_samples > 0 else inputs[ch][i]

            # Parallel comb filters with damping
            comb_sum = 0.0
            for c in range(len(COMB_TIMES)):
                comb_out = _combs[ch][c].tap(COMB_TIMES[c])

                # One-pole lowpass damping in feedback
                _lp[ch][c] = _lp[ch][c] * damp + comb_out * (1.0 - damp)

                _combs[ch][c].write(x + _lp[ch][c] * comb_gains[c])
                comb_sum += comb_out

            comb_sum /= len(COMB_TIMES)

            # Series allpass diffusers
            y = comb_sum
            for a in range(len(AP_TIMES)):
                ap_out = _aps[ch][a].tap(AP_TIMES[a])
                ap_in = y - 0.5 * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + 0.5 * ap_in

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
