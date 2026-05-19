import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "decay":      param(2, 15, unit="s", default=6),
    "modulation": param(0, 1, default=0.4),
    "brightness": param(0, 1, default=0.5),
    "mix":        mix(default=0.6),
}

COMB_TIMES = [1423, 1607, 1789, 1973, 2143, 2311]
AP_TIMES = [311, 443, 577]
_combs = None
_aps = None
_lp_state = None
_mod_phases = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ambient Wash — lush modulated reverb for ambient/textural use.

    A long-decay reverb with internal modulation that creates slowly
    evolving, shimmering tails. The modulation prevents metallic
    buildup and adds organic movement to sustained reverb tails.
    Designed for ambient guitar, synth pads, and soundscapes where
    the reverb IS the instrument. Inspired by Strymon BigSky and
    Eventide Blackhole.

    Params:
        decay:      Very long reverb tail (2–15 s)
        modulation: Internal chorus/pitch modulation (0–1)
        brightness: Tone of reverb tail (0–1)
        mix:        Wet/dry blend (higher for ambient use)
    """
    global _combs, _aps, _lp_state, _mod_phases

    decay_s = params["decay"]
    modulation = params["modulation"]
    brightness = params["brightness"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _combs is None:
        _combs = [[DelayLine(4096) for _ in COMB_TIMES] for _ in range(n_ch)]
        _aps = [[DelayLine(1024) for _ in AP_TIMES] for _ in range(n_ch)]
        _lp_state = [[0.0] * len(COMB_TIMES) for _ in range(n_ch)]
        _mod_phases = [0.1 * i for i in range(len(COMB_TIMES))]

    damp = (1.0 - brightness) * 0.6
    mod_depth = modulation * 4.0  # samples of modulation

    comb_gains = []
    for ct in COMB_TIMES:
        if decay_s > 0:
            comb_gains.append(10.0 ** (-3.0 * ct / (decay_s * sample_rate)))
        else:
            comb_gains.append(0.0)

    # Different mod rates per comb for organic movement
    mod_rates = [0.3, 0.47, 0.71, 0.23, 0.59, 0.37]

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i]

            comb_sum = 0.0
            for c in range(len(COMB_TIMES)):
                # Modulated read position
                mod = math.sin(two_pi * _mod_phases[c]) * mod_depth
                read_time = max(1.0, COMB_TIMES[c] + mod)

                comb_out = _combs[ch][c].read(read_time)
                _lp_state[ch][c] = _lp_state[ch][c] * damp + comb_out * (1.0 - damp)
                _combs[ch][c].write(x + _lp_state[ch][c] * comb_gains[c])
                comb_sum += comb_out

            comb_sum /= len(COMB_TIMES)

            y = comb_sum
            for a in range(len(AP_TIMES)):
                ap_out = _aps[ch][a].tap(AP_TIMES[a])
                ap_in = y - 0.5 * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + 0.5 * ap_in

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix

    # Advance mod phases
    for c in range(len(COMB_TIMES)):
        _mod_phases[c] = (_mod_phases[c] + mod_rates[c] / sample_rate) % 1.0
