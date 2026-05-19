import numpy as np
import math
from conjuredsp.params import param, mix

PARAMS = {
    "skip":    param(0, 0.1, default=0.02),
    "repeat":  param(0, 0.1, default=0.03),
    "noise":   param(0, 0.5, default=0.1),
    "mix":     mix(default=0.7),
}

_rng_state = 12345

def _rng():
    global _rng_state
    _rng_state = (_rng_state * 1664525 + 1013904223) & 0xFFFFFFFF
    return _rng_state / 4294967296.0

_prev_sample = [0.0, 0.0]
_skip_counter = [0, 0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Data Corrupt — audio-as-data corruption simulation.

    Simulates what happens when audio data gets corrupted in
    transmission: dropped samples (skip), stuck values (repeat),
    and bit errors (noise). Creates digital artifacts reminiscent
    of corrupted audio files, broken streaming, or glitched data.
    Used in glitch art, experimental music, and sound design for
    digital decay aesthetics.

    Params:
        skip:   Probability of dropping a sample (0–0.1)
        repeat: Probability of a sample getting stuck (0–0.1)
        noise:  Random data error injection (0–0.5)
        mix:    Wet/dry blend
    """
    global _prev_sample, _skip_counter

    skip_prob = params["skip"]
    repeat_prob = params["repeat"]
    noise = params["noise"]
    wet_mix = params["mix"]

    for ch in range(len(inputs)):
        prev = _prev_sample[ch] if ch < len(_prev_sample) else 0.0

        for i in range(frame_count):
            x = inputs[ch][i]
            y = x

            # Skip: drop sample, hold previous value
            if _rng() < skip_prob:
                y = prev
            # Repeat: get stuck on current value
            elif _rng() < repeat_prob:
                _skip_counter[ch] = 2 + int(_rng() * (20 - 2 + 1))

            if _skip_counter[ch] > 0:
                y = prev
                _skip_counter[ch] -= 1
            else:
                prev = y

            # Data error noise
            if _rng() < noise * 0.1:
                y += (_rng() - 0.5) * noise * 2.0

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + y * wet_mix

        if ch < len(_prev_sample):
            _prev_sample[ch] = prev
