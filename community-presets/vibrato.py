import numpy as np
import math
from conjuredsp.params import param
from conjuredsp.buffers import DelayLine

PARAMS = {
    "rate":  param(0.5, 14, unit="Hz", default=5),
    "depth": param(0, 1, default=0.5),
}

MAX_DELAY = 1024
_delays = None
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Vibrato — pure pitch modulation.

    Unlike chorus (which mixes dry and wet), vibrato modulates pitch
    without any dry signal. A sine LFO varies the read position in a
    delay line, creating periodic pitch variation. Used on vocals,
    guitar, electric piano, and organ. The depth control goes from
    subtle natural vibrato to extreme pitch wobble.

    Params:
        rate:  LFO speed (0.5–14 Hz)
        depth: Pitch deviation amount (0–1)
    """
    global _delays, _phase

    rate = params["rate"]
    depth = params["depth"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    two_pi = 2.0 * math.pi
    max_depth_samples = depth * 10.0  # up to 10 samples of deviation
    center_delay = 15.0  # center delay in samples

    for i in range(frame_count):
        mod = math.sin(two_pi * _phase) * max_depth_samples
        delay_samples = center_delay + mod

        for ch in range(n_ch):
            _delays[ch].write(inputs[ch][i])
            outputs[ch][i] = _delays[ch].read_cubic(max(1.0, delay_samples))

        _phase = (_phase + rate / sample_rate) % 1.0
