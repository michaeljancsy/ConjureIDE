import numpy as np
import math
from conjuredsp.params import freq, param

PARAMS = {
    "cutoff":    freq(default=1000),
    "resonance": param(0, 4, default=1),
    "drive":     param(1, 5, unit="x", default=1),
}

# 4-pole state per channel
_state = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Ladder Filter — Moog-style 24 dB/octave resonant lowpass.

    Models the iconic 4-pole transistor ladder filter. Each pole is
    a simple one-pole lowpass, cascaded for a steep 24 dB/octave
    rolloff. Feedback from the output to the input creates resonance
    that can self-oscillate at maximum settings. THE synth filter —
    the sound of Moog, Minimoog, and countless analog synthesizers.
    Also sounds amazing on drums, bass, and as a DJ filter.

    Params:
        cutoff:    Filter cutoff frequency (20–20000 Hz)
        resonance: Resonance / feedback (0–4, self-oscillates near 4)
        drive:     Input saturation (1–5x)
    """
    global _state

    cutoff_hz = params["cutoff"]
    resonance = params["resonance"]
    drive = params["drive"]

    # Coefficient for one-pole sections
    f = 2.0 * math.sin(math.pi * min(cutoff_hz, sample_rate * 0.45) / sample_rate)

    for ch in range(len(inputs)):
        s = _state[ch] if ch < len(_state) else [0.0, 0.0, 0.0, 0.0]

        for i in range(frame_count):
            x = inputs[ch][i] * drive

            # Feedback (resonance)
            x -= resonance * s[3]

            # Soft clip the feedback to prevent blowup
            x = math.tanh(x)

            # 4 cascaded one-pole lowpass stages
            s[0] += f * (x - s[0])
            s[1] += f * (s[0] - s[1])
            s[2] += f * (s[1] - s[2])
            s[3] += f * (s[2] - s[3])

            outputs[ch][i] = s[3]

        if ch < len(_state):
            _state[ch] = s
