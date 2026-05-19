import numpy as np
import math
from conjuredsp.params import choice
from conjuredsp.buffers import DelayLine

PARAMS = {
    "mode": choice("I", "II", "III", "IV", default="II"),
}

MAX_DELAY = 2048
_delays = None
_phases = [0.0, 0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Dimension Chorus — Roland Dimension D inspired.

    The legendary Dimension D had just 4 buttons — no knobs. Each mode
    is a carefully voiced combination of delay time, modulation depth,
    and rate that produces a wide, spacious chorus without the obvious
    "swooshing" of typical chorus effects. Mode I is subtle, Mode IV
    is extreme. Modes can be combined (I+III, etc.) for complex textures.
    The secret weapon of countless 80s pop/synth records.

    Params:
        mode: Dimension mode (I = subtle, IV = extreme)
    """
    global _delays, _phases

    mode = int(params["mode"])

    n_ch = len(inputs)

    if _delays is None:
        _delays = [[DelayLine(MAX_DELAY) for _ in range(3)] for _ in range(n_ch)]

    # Each mode has specific settings (delay, depth, rate)
    mode_params = [
        # (base_delay_ms, depth_ms, rate_hz)
        (3.0, 0.3, 0.5),    # Mode I — subtle
        (5.0, 0.8, 0.7),    # Mode II — moderate
        (7.0, 1.5, 1.0),    # Mode III — wide
        (10.0, 3.0, 0.4),   # Mode IV — extreme
    ]

    base_ms, depth_ms, rate = mode_params[mode]
    base_samples = base_ms * 0.001 * sample_rate
    depth_samples = depth_ms * 0.001 * sample_rate

    two_pi = 2.0 * math.pi

    # 3 voices with carefully offset phases
    phase_offsets = [0.0, two_pi / 3.0, 2.0 * two_pi / 3.0]
    voice_rates = [rate, rate * 1.07, rate * 0.93]

    for i in range(frame_count):
        for ch in range(n_ch):
            x = inputs[ch][i]

            wet = 0.0
            for v in range(3):
                _delays[ch][v].write(x)
                mod = math.sin(two_pi * _phases[v] + phase_offsets[v])
                delay = base_samples + mod * depth_samples
                wet += _delays[ch][v].read_cubic(max(1.0, delay))

            wet /= 3.0

            # Dimension D uses roughly 50/50 dry/wet
            outputs[ch][i] = x * 0.5 + wet * 0.5

        for v in range(3):
            _phases[v] = (_phases[v] + voice_rates[v] / sample_rate) % 1.0
