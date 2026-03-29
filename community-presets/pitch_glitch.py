import numpy as np
import math
import random
from conjuredsp.params import param, mix
from conjuredsp.buffers import DelayLine

PARAMS = {
    "rate":   param(0.5, 20, unit="Hz", default=4),
    "range":  param(1, 24, unit="st", default=12),
    "chance": param(0, 1, default=0.5),
    "mix":    mix(default=0.5),
}

MAX_DELAY = 8192
_delays = None
_phase = 0.0
_current_pitch = 1.0
_ramp = 0.0


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Pitch Glitch — random pitch-jumping effect.

    At random intervals, the pitch jumps to a random transposition
    within the range. Creates stuttery, glitchy, broken-electronics
    textures. The chance control determines how often glitches
    occur. Low chance = occasional surprises, high chance = chaos.
    Great for electronic music, IDM, experimental hip-hop, and
    sound design.

    Params:
        rate:   Clock rate for glitch opportunities (0.5–20 Hz)
        range:  Maximum pitch shift range in semitones (1–24)
        chance: Probability of glitch on each tick (0–1)
        mix:    Wet/dry blend
    """
    global _delays, _phase, _current_pitch, _ramp

    rate = params["rate"]
    pitch_range = params["range"]
    chance = params["chance"]
    wet_mix = params["mix"]

    n_ch = len(inputs)

    if _delays is None:
        _delays = [DelayLine(MAX_DELAY) for _ in range(n_ch)]

    base_delay = 200.0

    for i in range(frame_count):
        old_phase = _phase
        _phase = (_phase + rate / sample_rate) % 1.0

        # On each clock tick, maybe glitch
        if _phase < old_phase:
            if random.random() < chance:
                # Random pitch shift in semitones
                st = random.uniform(-pitch_range, pitch_range)
                _current_pitch = 2.0 ** (st / 12.0)
            else:
                _current_pitch = 1.0

        # Varying delay creates pitch shift
        _ramp = (_ramp + (1.0 - _current_pitch)) % MAX_DELAY
        delay = base_delay + _ramp
        delay = max(1.0, delay % MAX_DELAY)

        for ch in range(n_ch):
            _delays[ch].write(inputs[ch][i])
            pitched = _delays[ch].read_cubic(delay)

            outputs[ch][i] = inputs[ch][i] * (1.0 - wet_mix) + pitched * wet_mix
