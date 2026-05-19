import numpy as np
import math
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "voices":  param(2, 6, default=3),
    "rate":    param(0.2, 2, unit="Hz", default=0.6),
    "depth":   param(0.5, 10, unit="ms", default=3),
    "mix":     mix(default=0.6),
}

MAX_DELAY = 2048
_delays = None
_phases = None


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    String Ensemble — multi-voice chorus (Roland Dimension D style).

    Creates multiple detuned copies using independently modulated delay
    lines. Each voice has a different LFO rate and phase, producing a
    rich, animated ensemble effect without metallic artifacts. The
    classic sound of 70s/80s string machines, synth pads, and the
    legendary Roland Dimension D chorus unit.

    Params:
        voices: Number of chorus voices (2–6)
        rate:   Base LFO rate (0.2–2 Hz)
        depth:  Modulation depth (0.5–10 ms)
        mix:    Wet/dry blend
    """
    global _delays, _phases

    n_voices = int(params["voices"])
    rate = params["rate"]
    depth_ms = params["depth"]
    wet_mix = params["mix"]

    n_ch = len(inputs)
    two_pi = 2.0 * math.pi

    if _delays is None or len(_delays) != n_ch:
        _delays = [[DelayLine(MAX_DELAY) for _ in range(6)] for _ in range(n_ch)]
        _phases = [i * 0.13 + 0.05 for i in range(6)]  # staggered phases

    depth_samples = depth_ms * 0.001 * sample_rate
    base_delay = depth_samples + 5.0

    for i in range(frame_count):
        for ch in range(n_ch):
            x = inputs[ch][i]

            # Write to all delay lines
            for v in range(n_voices):
                _delays[ch][v].write(x)

            # Sum modulated reads
            wet = 0.0
            for v in range(n_voices):
                # Each voice gets slightly different rate
                voice_rate = rate * (0.8 + 0.4 * v / max(n_voices - 1, 1))
                mod = math.sin(two_pi * _phases[v]) * depth_samples
                delay = base_delay + mod
                wet += _delays[ch][v].read_cubic(max(1.0, delay))

            wet /= n_voices

            outputs[ch][i] = x * (1.0 - wet_mix) + wet * wet_mix

        # Advance all phases
        for v in range(n_voices):
            voice_rate = rate * (0.8 + 0.4 * v / max(n_voices - 1, 1))
            _phases[v] = (_phases[v] + voice_rate / sample_rate) % 1.0
