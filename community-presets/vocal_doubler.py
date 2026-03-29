import numpy as np
import math
import random
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "depth":   param(5, 40, unit="ms", default=15),
    "detune":  param(0, 1, default=0.3),
    "spread":  param(0, 1, default=0.7),
    "mix":     mix(default=0.4),
}

MAX_DELAY = 4096
_delays = None
_phase = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Vocal Doubler — ADT (Automatic Double Tracking).

    Creates a realistic doubled vocal by adding a slightly delayed
    and detuned copy. The delay and detuning vary slightly over time
    to simulate a human re-performance (no two takes are identical).
    The spread control pans the double for stereo width. Invented
    at Abbey Road Studios for The Beatles — the original ADT effect
    used by John Lennon.

    Params:
        depth:  Delay offset for the double (5–40 ms)
        detune: Pitch variation amount (0–1)
        spread: Stereo spread of the double (0 = center, 1 = wide)
        mix:    Doubled signal level
    """
    global _delays, _phase

    depth_ms = params["depth"]
    detune = params["detune"]
    spread = params["spread"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    base_delay = depth_ms * 0.001 * sample_rate
    mod_depth = detune * 3.0  # samples of pitch modulation

    for i in range(frame_count):
        # Slow, irregular modulation (simulates human timing variation)
        mod = math.sin(two_pi * _phase * 0.7) * mod_depth
        mod += math.sin(two_pi * _phase * 1.3) * mod_depth * 0.5
        mod += (random.random() - 0.5) * detune * 0.5

        delay_samples = max(1.0, base_delay + mod)

        for ch in range(n_ch):
            _delays[ch].write(inputs[ch][i])
            doubled = _delays[ch].read_cubic(delay_samples)

            if n_ch >= 2 and spread > 0:
                # Pan: original centered, double spread out
                if ch == 0:
                    outputs[ch][i] = inputs[ch][i] + doubled * wet_mix * (1.0 - spread * 0.5)
                else:
                    outputs[ch][i] = inputs[ch][i] + doubled * wet_mix * (1.0 + spread * 0.5)
            else:
                outputs[ch][i] = inputs[ch][i] + doubled * wet_mix

        _phase = (_phase + 1.0 / sample_rate) % 1.0
