import numpy as np
import math
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "time":      time_ms(min=50, max=500, default=200),
    "diffusion": param(0, 1, default=0.7),
    "feedback":  param(0, 0.9, default=0.4),
    "damping":   param(0, 1, default=0.3),
    "mix":       mix(default=0.5),
}

MAX_DELAY = 48000
_main_delays = None
_ap_delays = None
_lp = None

# Allpass delay times (prime numbers for maximal diffusion)
AP_TIMES = [113, 337, 571, 907]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Diffusion Delay — smeared, reverb-like echoes.

    Passes delay repeats through a chain of allpass diffusers that
    smear each echo into a wash. At low diffusion, echoes are
    distinct; at high diffusion, echoes blur into reverb-like tails.
    Bridges the gap between delay and reverb. Great for ambient pads,
    atmospheric vocals, and cinematic soundscapes.

    Params:
        time:      Main delay time (50–500 ms)
        diffusion: Allpass smearing amount (0–1)
        feedback:  Repeat amount (0–0.9)
        damping:   High-frequency loss per repeat (0–1)
        mix:       Wet/dry blend
    """
    global _main_delays, _ap_delays, _lp

    delay_ms = params["time"]
    diffusion = params["diffusion"]
    feedback = params["feedback"]
    damping = params["damping"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _main_delays is None:
        _main_delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]
        _ap_delays = [[DelayLine(1024) for _ in range(4)] for _ in range(n_ch)]
        _lp = [Biquad() for _ in range(n_ch)]

    delay_samples = max(1.0, delay_ms * 0.001 * sample_rate)
    lp_freq = 14000.0 - damping * 10000.0

    ap_coeff = diffusion * 0.7

    for ch in range(n_ch):
        _lp[ch].set_coeffs(BiquadCoeffs.lowpass(lp_freq, 0.7, sample_rate))

        for i in range(frame_count):
            delayed = _main_delays[ch].read(delay_samples)

            # Diffusion: cascade of allpass filters
            y = delayed
            for ap_idx in range(4):
                ap_delay = _ap_delays[ch][ap_idx]
                ap_out = ap_delay.tap(AP_TIMES[ap_idx])
                ap_in = y - ap_coeff * ap_out
                ap_delay.write(ap_in)
                y = ap_out + ap_coeff * ap_in

            # Damping
            y = _lp[ch].process_sample(y)

            _main_delays[ch].write(inputs[ch][i] + y * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix
