import numpy as np
import math
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "length":  time_ms(min=50, max=500, default=200),
    "density": param(0, 1, default=0.7),
    "mix":     mix(default=0.5),
}

COMB_TIMES = [997, 1153, 1327, 1489]
AP_TIMES = [211, 317]
_combs = None
_aps = None
_gate_env = 0.0
_gate_counter = 0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Gated Reverb — 80s drum reverb.

    A dense reverb that cuts off abruptly after a set time, creating
    the explosive, punchy reverb sound that defined 80s drums. Made
    famous by Phil Collins' "In the Air Tonight" (discovered by
    accident with a talkback compressor). Essential for big drum
    sounds, synthwave, and retrowave productions.

    Params:
        length:  Gate hold time before cutoff (50–500 ms)
        density: Reverb density/feedback (0–1)
        mix:     Wet/dry blend
    """
    global _combs, _aps, _gate_env, _gate_counter

    length_ms = params["length"]
    density = params["density"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    gate_samples = int(length_ms * 0.001 * sample_rate)

    if _combs is None:
        _combs = [[DelayLine(2048) for _ in COMB_TIMES] for _ in range(n_ch)]
        _aps = [[DelayLine(512) for _ in AP_TIMES] for _ in range(n_ch)]

    feedback = 0.5 + density * 0.4
    threshold = 0.05

    for i in range(frame_count):
        # Detect transients to trigger gate
        peak = 0.0
        for ch in range(n_ch):
            peak = max(peak, abs(inputs[ch][i]))

        if peak > threshold:
            _gate_counter = gate_samples
            _gate_env = 1.0

        if _gate_counter > 0:
            _gate_counter -= 1
        else:
            # Sharp gate cutoff
            _gate_env *= 0.95
            if _gate_env < 0.001:
                _gate_env = 0.0

        for ch in range(n_ch):
            x = inputs[ch][i]

            # Dense reverb via parallel combs
            comb_sum = 0.0
            for c in range(len(COMB_TIMES)):
                comb_out = _combs[ch][c].tap(COMB_TIMES[c])
                _combs[ch][c].write(x + comb_out * feedback * _gate_env)
                comb_sum += comb_out

            comb_sum /= len(COMB_TIMES)

            # Allpass diffusion
            y = comb_sum
            for a in range(len(AP_TIMES)):
                ap_out = _aps[ch][a].tap(AP_TIMES[a])
                ap_in = y - 0.5 * ap_out
                _aps[ch][a].write(ap_in)
                y = ap_out + 0.5 * ap_in

            y *= _gate_env

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
