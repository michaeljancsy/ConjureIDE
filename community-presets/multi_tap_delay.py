import numpy as np
import math
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "time":     time_ms(min=50, max=500, default=200),
    "tap2":     param(0.25, 2, unit="x", default=0.5),
    "tap3":     param(0.25, 2, unit="x", default=0.75),
    "tap4":     param(0.25, 2, unit="x", default=1.5),
    "feedback": param(0, 0.9, default=0.3),
    "mix":      mix(default=0.5),
}

MAX_DELAY = 96000
_delays = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Multi-Tap Delay — 4-tap rhythmic delay.

    Creates complex rhythmic echo patterns by reading the delay line
    at 4 different positions. Tap 1 is the base time; taps 2-4 are
    multiples of that time. Adjust tap ratios to create dotted,
    triplet, or polyrhythmic patterns. Essential for ambient guitar,
    EDM builds, and soundtrack design.

    Params:
        time:     Base delay time (50–500 ms)
        tap2:     Tap 2 time ratio (0.25–2x base)
        tap3:     Tap 3 time ratio (0.25–2x base)
        tap4:     Tap 4 time ratio (0.25–2x base)
        feedback: Regeneration amount (0–0.9)
        mix:      Wet/dry blend
    """
    global _delays

    base_ms = params["time"]
    tap2_ratio = params["tap2"]
    tap3_ratio = params["tap3"]
    tap4_ratio = params["tap4"]
    feedback = params["feedback"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    tap_times = [
        base_ms * 0.001 * sample_rate,
        base_ms * tap2_ratio * 0.001 * sample_rate,
        base_ms * tap3_ratio * 0.001 * sample_rate,
        base_ms * tap4_ratio * 0.001 * sample_rate,
    ]

    # Clamp taps
    tap_times = [max(1.0, min(t, MAX_DELAY - 1)) for t in tap_times]

    # Tap levels (later taps slightly quieter)
    levels = [1.0, 0.8, 0.6, 0.4]

    for i in range(frame_count):
        for ch in range(n_ch):
            # Sum all taps
            wet = 0.0
            for t in range(4):
                wet += _delays[ch].tap(int(tap_times[t])) * levels[t]

            wet *= 0.25  # normalize

            _delays[ch].write(inputs[ch][i] + wet * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + wet * wet_mix
