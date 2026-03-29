import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "decay":      param(3, 20, unit="s", default=8),
    "sparkle":    param(0, 1, default=0.6),
    "modulation": param(0, 1, default=0.5),
    "mix":        mix(default=0.7),
}

COMB_TIMES = [1297, 1451, 1619, 1783, 1949, 2099]
AP_TIMES = [307, 419, 547]
_combs = None
_aps = None
_lp_state = None
_mod_phases = None
_shimmer_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ethereal Shimmer — lush shimmer pad creator.

    Combines an ultra-long reverb with modulation and pitch shimmer
    to transform any input into an ethereal, crystalline pad. The
    sparkle control adds octave-up content that cascades through
    the reverb, while modulation prevents static buildup. Feed in
    a single guitar chord or piano note and it becomes an infinite,
    evolving ambient texture.

    Params:
        decay:      Reverb tail length (3–20 s)
        sparkle:    Octave shimmer amount (0–1)
        modulation: Internal movement (0–1)
        mix:        Wet/dry blend
    """
    global _combs, _aps, _lp_state, _mod_phases, _shimmer_phase

    decay_s = params["decay"]
    sparkle = params["sparkle"]
    modulation = params["modulation"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _combs is None:
        _combs = [[DelayLine(4096) for _ in COMB_TIMES] for _ in range(n_ch)]
        _aps = [[DelayLine(1024) for _ in AP_TIMES] for _ in range(n_ch)]
        _lp_state = [[0.0] * len(COMB_TIMES) for _ in range(n_ch)]
        _mod_phases = [i * 0.17 for i in range(len(COMB_TIMES))]

    comb_gains = []
    for ct in COMB_TIMES:
        if decay_s > 0:
            comb_gains.append(10.0 ** (-3.0 * ct / (decay_s * sample_rate)))
        else:
            comb_gains.append(0.0)

    mod_depth = modulation * 5.0
    mod_rates = [0.23, 0.37, 0.53, 0.19, 0.41, 0.31]

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i]

            comb_sum = 0.0
            for c in range(len(COMB_TIMES)):
                mod = math.sin(two_pi * _mod_phases[c]) * mod_depth
                read_time = max(1.0, COMB_TIMES[c] + mod)

                comb_out = _combs[ch][c].read(read_time)

                # Light damping
                _lp_state[ch][c] = _lp_state[ch][c] * 0.2 + comb_out * 0.8

                # Shimmer in feedback
                shimmer_sig = _lp_state[ch][c] * math.sin(two_pi * _shimmer_phase * 2.0)
                fb = _lp_state[ch][c] * (1.0 - sparkle) + shimmer_sig * sparkle

                _combs[ch][c].write(x + fb * comb_gains[c])
                comb_sum += comb_out

            comb_sum /= len(COMB_TIMES)

            y = comb_sum
            for a in range(len(AP_TIMES)):
                ap_out = _aps[ch][a].tap(AP_TIMES[a])
                ap_in = y - 0.5 * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + 0.5 * ap_in

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix

    _shimmer_phase = (_shimmer_phase + 440.0 / sample_rate) % 1.0
    for c in range(len(COMB_TIMES)):
        _mod_phases[c] = (_mod_phases[c] + mod_rates[c] / sample_rate) % 1.0
