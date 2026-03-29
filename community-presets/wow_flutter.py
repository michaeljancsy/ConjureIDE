import numpy as np
import math
import random
from conjuredsp.params import param
from conjuredsp.buffers import DelayLine

PARAMS = {
    "wow":     param(0, 1, default=0.3),
    "flutter": param(0, 1, default=0.4),
    "noise":   param(0, 1, default=0.1),
}

MAX_DELAY = 2048
_delays = None
_wow_phase = 0.0
_flutter_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Wow & Flutter — tape/vinyl speed imperfections.

    Wow is slow pitch wobble (from tape hub irregularities or warped
    vinyl). Flutter is faster pitch jitter (from capstan/motor
    irregularities). Together they create the nostalgic imperfection
    of analog playback. Add noise for extra lo-fi character. Perfect
    for "tape" treatments on synths, drums, and lo-fi productions.

    Params:
        wow:     Slow speed variation depth (0–1)
        flutter: Fast speed variation depth (0–1)
        noise:   Added pitch noise/randomness (0–1)
    """
    global _delays, _wow_phase, _flutter_phase

    wow = params["wow"]
    flutter = params["flutter"]
    noise = params["noise"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    # Wow: ~0.5 Hz slow wobble, up to 5 samples deviation
    wow_rate = 0.5
    wow_depth = wow * 5.0

    # Flutter: ~6 Hz fast jitter, up to 2 samples deviation
    flutter_rate = 6.0
    flutter_depth = flutter * 2.0

    base_delay = 20.0

    for i in range(frame_count):
        wow_mod = math.sin(two_pi * _wow_phase) * wow_depth
        flutter_mod = math.sin(two_pi * _flutter_phase) * flutter_depth
        noise_mod = (random.random() * 2.0 - 1.0) * noise * 1.0

        delay = base_delay + wow_mod + flutter_mod + noise_mod
        delay = max(1.0, delay)

        for ch in range(n_ch):
            _delays[ch].write(inputs[ch][i])
            outputs[ch][i] = _delays[ch].read_cubic(delay)

        _wow_phase = (_wow_phase + wow_rate / sample_rate) % 1.0
        _flutter_phase = (_flutter_phase + flutter_rate / sample_rate) % 1.0
