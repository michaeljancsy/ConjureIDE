import numpy as np
import math
import random
from conjuredsp.params import param, time_ms, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "time":     time_ms(min=50, max=600, default=250),
    "feedback": param(0, 0.95, default=0.5),
    "degrade":  param(0, 1, default=0.6),
    "mix":      mix(default=0.5),
}

MAX_DELAY = 64000
_delays = None
_held = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Lo-Fi Delay — degraded, deteriorating echoes.

    Each repeat is progressively degraded: bit-crushed, sample-rate
    reduced, and filtered. Repeats become increasingly distorted and
    unrecognizable, like a tape being recorded over and over. At high
    feedback, the signal dissolves into beautiful noise. Perfect for
    lo-fi hip hop, vaporwave, ambient noise, and glitch music.

    Params:
        time:     Delay time (50–600 ms)
        feedback: Repeat amount (0–0.95)
        degrade:  Degradation amount per repeat (0–1)
        mix:      Wet/dry blend
    """
    global _delays, _held

    delay_ms = params["time"]
    feedback = params["feedback"]
    degrade = params["degrade"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    delay_samples = max(1.0, delay_ms * 0.001 * sample_rate)

    # Degradation settings
    bit_depth = max(2, int(16 - degrade * 12))  # 16 to 4 bits
    levels = 2 ** bit_depth
    downsample = max(1, int(1 + degrade * 8))  # 1x to 9x

    for i in range(frame_count):
        for ch in range(n_ch):
            delayed = _delays[ch].read(delay_samples)

            # Bit crush the feedback
            delayed = round(delayed * levels) / levels

            # Sample rate reduce
            if i % downsample == 0:
                _held[ch] = delayed
            delayed = _held[ch]

            # Add tiny noise
            delayed += (random.random() - 0.5) * degrade * 0.01

            _delays[ch].write(inputs[ch][i] + delayed * feedback)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + delayed * wet_mix
