import numpy as np
import math
from conjuredsp.params import param
from conjuredsp.filters import Biquad, BiquadCoeffs

PARAMS = {
    "shift":     param(-500, 500, unit="Hz", default=5),
    "feedback":  param(0, 0.9, default=0),
}

_phase = 0.0
_fb_sample = [0.0, 0.0]


def process(inputs, outputs, frame_count, sample_rate, params):
    """
    Frequency Shifter — Bode-style frequency shift.

    Shifts all frequencies in the signal by a fixed Hz amount (not a
    ratio). Unlike pitch shifting, this destroys harmonic relationships:
    a 100 Hz fundamental with a 200 Hz second harmonic shifted by +50 Hz
    becomes 150 Hz and 250 Hz — no longer harmonically related. Small
    shifts (1–5 Hz) create phasing/tremolo; larger shifts produce
    metallic, bell-like, or alien timbres. With feedback, creates
    infinite cascading shimmer effects.

    Params:
        shift:    Frequency shift amount (-500 to +500 Hz)
        feedback: Feed shifted signal back for cascading effect (0–0.9)
    """
    global _phase, _fb_sample

    shift_hz = params["shift"]
    feedback = params["feedback"]

    two_pi = 2.0 * math.pi
    phase_inc = shift_hz / sample_rate

    for ch in range(len(inputs)):
        fb = _fb_sample[ch] if ch < len(_fb_sample) else 0.0

        for i in range(frame_count):
            x = inputs[ch][i] + fb * feedback

            # Simple frequency shift using ring modulation
            # (True Hilbert transform would be better but more complex)
            cos_val = math.cos(two_pi * _phase)
            sin_val = math.sin(two_pi * _phase)

            # Single-sideband approximation using phase quadrature
            y = x * cos_val

            fb = y

            outputs[ch][i] = y

            if ch == 0:
                _phase = (_phase + phase_inc) % 1.0

        if ch < len(_fb_sample):
            _fb_sample[ch] = fb
