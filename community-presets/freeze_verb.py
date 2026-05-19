import numpy as np
import math
from conjuredsp.params import toggle, param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "freeze": toggle(default=0),
    "blur":   param(0, 1, default=0.5),
    "mix":    mix(default=0.5),
}

COMB_TIMES = [1259, 1433, 1601, 1777, 1949, 2111]
AP_TIMES = [293, 401, 521]
_combs = None
_aps = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Freeze Reverb — infinite sustain / sound freeze.

    When the freeze toggle is engaged, the reverb feedback goes to
    unity (1.0) and new input is blocked — the current reverb tail
    sustains infinitely. Release freeze to let it decay naturally.
    The blur control adds diffusion to smooth the frozen sound into
    a pad-like texture. Perfect for ambient drones, creating pad
    layers from any sound, or dramatic performance effects.

    Params:
        freeze: Toggle infinite sustain on/off
        blur:   Diffusion amount (0 = clear, 1 = smooth)
        mix:    Wet/dry blend
    """
    global _combs, _aps

    frozen = params["freeze"] > 0.5
    blur = params["blur"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _combs is None:
        _combs = [[DelayLine(4096) for _ in COMB_TIMES] for _ in range(n_ch)]
        _aps = [[DelayLine(1024) for _ in AP_TIMES] for _ in range(n_ch)]

    # When frozen: feedback = 1.0, no new input
    # When not frozen: normal reverb with moderate decay
    feedback = 1.0 if frozen else 0.85
    input_gain = 0.0 if frozen else 1.0
    ap_coeff = 0.3 + blur * 0.4

    for ch in range(n_ch):
        for i in range(frame_count):
            x = inputs[ch][i] * input_gain

            comb_sum = 0.0
            for c in range(len(COMB_TIMES)):
                comb_out = _combs[ch][c].tap(COMB_TIMES[c])
                _combs[ch][c].write(x + comb_out * feedback)
                comb_sum += comb_out

            comb_sum /= len(COMB_TIMES)

            y = comb_sum
            for a in range(len(AP_TIMES)):
                ap_out = _aps[ch][a].tap(AP_TIMES[a])
                ap_in = y - ap_coeff * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + ap_coeff * ap_in

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
